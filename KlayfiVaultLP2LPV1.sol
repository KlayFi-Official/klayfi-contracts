// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

/*

*
* MIT License
* ===========
*
* Copyright (c) 2021 KlayFi
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import {PoolConstant} from "./library/PoolConstant.sol";
import "./interfaces/IKSP.sol";
import "./interfaces/IKSLP.sol";
import "./interfaces/IStrategy.sol";
import "./interfaces/IZapKlayswap.sol";

import "./VaultController.sol";

contract VaultLP2LP is VaultController, IStrategy {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint256;

    uint256 public version = 1; // V1
    address[] public additionalRewardTokens;

    /* ========== LAUNCHPAD START ========== */
    bool launchpadPhase = true;
    bool launchpadPhaseConfigurable = true;
    address public launchpadRewardReceiver;
    uint256 deployedTimestamp;

    uint public constant UNLOCK_PERIOD = 28 days;

    modifier notInLaunchpadPhase {
        require(launchpadPhase == false || (block.timestamp >= deployedTimestamp.add(UNLOCK_PERIOD)));
        _;
    }
    
    modifier onlyInLaunchpadPhase {
        require(launchpadPhase == true);
        _;
    }

    function setLaunchpadPhase(bool _launchpadPhase) external onlyOwner {
        require(launchpadPhaseConfigurable == true);
        launchpadPhase = _launchpadPhase;
    }

    function setLaunchpadRewardReceiver(address _receiver) external onlyOwner {
        launchpadRewardReceiver = _receiver;
    }

    function endLaunchpadPhase() external onlyOwner {
        launchpadPhase = false;
        launchpadPhaseConfigurable = false;
    }
    
    function checkUnlockPeriodPassed() external view returns (bool) {
        return block.timestamp >= deployedTimestamp.add(UNLOCK_PERIOD);
    }

    /* ========== LAUNCHPAD END ========== */

    /* ========== CONSTANTS ============= */
    IBEP20 private constant KSP = IBEP20(0xC6a2Ad8cC6e4A7E08FC37cC5954be07d499E7654);
    PoolConstant.PoolTypes public constant override poolType = PoolConstant.PoolTypes.FlipToFlip;

    IZapKlayswap public zap;

    uint private constant DUST = 1000;

    /* ========== STATE VARIABLES ========== */

    address private _token0;
    address private _token1;

    uint public totalShares;
    mapping (address => uint) private _shares;
    mapping (address => uint) private _principal;
    mapping (address => uint) private _depositedAt;

    uint public kspHarvested;

    /* ========== MODIFIER ========== */
    
    modifier updateKSPHarvested {
        uint before = KSP.balanceOf(address(this));
        _;
        uint _after = KSP.balanceOf(address(this));
        kspHarvested = kspHarvested.add(_after).sub(before);
    }

    /* ========== INITIALIZER ========== */

    function initialize(address _token) external initializer {
        deployedTimestamp = block.timestamp;

        // _token === _stakingToken
        __VaultController_init(IBEP20(_token));

        KSP.safeApprove(address(KSP), uint256(-1));
        // Use `setZap` instead.
        // KSP.safeApprove(address(zap), uint(-1));
    }

    /* ========== VIEW FUNCTIONS ========== */

    function totalSupply() external view override returns (uint) {
        return totalShares;
    }

    function balance() public view override returns (uint amount) {
        return IBEP20(_stakingToken).balanceOf(address(this));
    }

    function balanceOf(address account) public view override returns(uint) {
        if (totalShares == 0) return 0;
        return balance().mul(sharesOf(account)).div(totalShares);
    }

    function withdrawableBalanceOf(address account) public view override returns (uint) {
        return balanceOf(account);
    }

    function sharesOf(address account) public view override returns (uint) {
        return _shares[account];
    }

    function principalOf(address account) public view override returns (uint) {
        return _principal[account];
    }

    function earned(address account) public view override returns (uint) {
        if (balanceOf(account) >= principalOf(account) + DUST) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    function depositedAt(address account) external view override returns (uint) {
        return _depositedAt[account];
    }

    function rewardsToken() external view override returns (address) {
        return address(_stakingToken);
    }

    function priceShare() external view override returns(uint) {
        if (totalShares == 0) return 1e18;
        return balance().mul(1e18).div(totalShares);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit(uint _amount) public override {
        _depositTo(_amount, msg.sender);
    }

    function depositAll() external override {
        deposit(_stakingToken.balanceOf(msg.sender));
    }

    function withdrawAll() external override notInLaunchpadPhase {
        uint amount = balanceOf(msg.sender);
        uint principal = principalOf(msg.sender);
        uint depositTimestamp = _depositedAt[msg.sender];

        totalShares = totalShares.sub(_shares[msg.sender]);
        delete _shares[msg.sender];
        delete _principal[msg.sender];
        delete _depositedAt[msg.sender];

        uint profit = amount > principal ? amount.sub(principal) : 0;

        uint withdrawalFee = canMint() ? _minter.withdrawalFee(principal, depositTimestamp) : 0;
        uint performanceFee = canMint() ? _minter.performanceFee(profit) : 0;
        if (withdrawalFee.add(performanceFee) > DUST) {
            _minter.mintForV2(address(_stakingToken), withdrawalFee, performanceFee, msg.sender, depositTimestamp);

            if (performanceFee > 0) {
                emit ProfitPaid(msg.sender, profit, performanceFee);
            }
            amount = amount.sub(withdrawalFee).sub(performanceFee);
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    function harvest() external override onlyKeeper {
        _harvest();

        uint before = _stakingToken.balanceOf(address(this));
        
        for (uint i = 0; i < additionalRewardTokens.length; i++) {
          address _additionalRewardToken = additionalRewardTokens[i];
          if (_additionalRewardToken != address(0)) {
            approveIfNeeded(_additionalRewardToken);
            IZapKlayswap(zap).zapInToken(address(_additionalRewardToken), IBEP20(_additionalRewardToken).balanceOf(address(this)), address(_stakingToken));
          }
        }

        IZapKlayswap(zap).zapInToken(address(KSP), kspHarvested, address(_stakingToken));
        uint harvested = _stakingToken.balanceOf(address(this)).sub(before);

        emit Harvested(harvested);

        kspHarvested = 0;
    }

    function _harvest() private updateKSPHarvested {
        IKSLP(address(_stakingToken)).claimReward();
    }

    function withdrawUnderlying(uint _amount) external notInLaunchpadPhase {
        uint amount = Math.min(_amount, _principal[msg.sender]);
        uint deltaShares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
        totalShares = totalShares.sub(deltaShares);
        _shares[msg.sender] = _shares[msg.sender].sub(deltaShares);
        _principal[msg.sender] = _principal[msg.sender].sub(amount);

        uint depositTimestamp = _depositedAt[msg.sender];
        uint withdrawalFee = canMint() ? _minter.withdrawalFee(amount, depositTimestamp) : 0;
        if (withdrawalFee > DUST) {
            _minter.mintForV2(address(_stakingToken), withdrawalFee, 0, msg.sender, depositTimestamp);
            amount = amount.sub(withdrawalFee);
        }

        _stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount, withdrawalFee);
    }

    function getReward() external override notInLaunchpadPhase {
        uint profit = earned(msg.sender);
        uint deltaShares = Math.min(profit.mul(totalShares).div(balance()), _shares[msg.sender]);
        totalShares = totalShares.sub(deltaShares);
        _shares[msg.sender] = _shares[msg.sender].sub(deltaShares);
        _cleanupIfDustShares();

        uint depositTimestamp = _depositedAt[msg.sender];
        uint performanceFee = canMint() ? _minter.performanceFee(profit) : 0;
        if (performanceFee > DUST) {
            _minter.mintForV2(address(_stakingToken), 0, performanceFee, msg.sender, depositTimestamp);
            profit = profit.sub(performanceFee);
        }

        _stakingToken.safeTransfer(msg.sender, profit);
        emit ProfitPaid(msg.sender, profit, performanceFee);
    }

    function claimLaunchpadRewards() external onlyOwner onlyInLaunchpadPhase {
        IKSLP(address(_stakingToken)).claimReward();

        IBEP20(KSP).transfer(launchpadRewardReceiver, IBEP20(KSP).balanceOf(address(this)));

        for (uint i = 0; i < additionalRewardTokens.length; i++) {
          address _additionalRewardToken = additionalRewardTokens[i];
          if (_additionalRewardToken != address(0)) {
            IBEP20(_additionalRewardToken).transfer(launchpadRewardReceiver, IBEP20(_additionalRewardToken).balanceOf(address(this)));
          }
        }
    }

    function approveIfNeeded(address token) internal {
      if (IBEP20(token).allowance(address(this), address(zap)) == 0) {
        IBEP20(token).safeApprove(address(zap), uint(-1));
      }
    }

    function pushAdditionalRewardToken(address _additionalToken) external onlyOwner {
      require(_additionalToken != address(_stakingToken), "_additionalToken != _stakingToken");
      require (_additionalToken != address(0));

      additionalRewardTokens.push(_additionalToken);
    }
    
    function popAdditionalRewardToken(address _additionalToken) external onlyOwner {
      require (_additionalToken != address(0));

      for (uint i=0; i < additionalRewardTokens.length; i++) {
        if (additionalRewardTokens[i] == _additionalToken) {
          delete additionalRewardTokens[i];
        }
      }
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _depositTo(uint _amount, address _to) private notPaused updateKSPHarvested {
        uint _pool = balance();
        uint _before = _stakingToken.balanceOf(address(this));
        _stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        uint _after = _stakingToken.balanceOf(address(this));
        _amount = _after.sub(_before); // Additional check for deflationary tokens
        
        // New shares
        uint deltaShares = 0;
        if (totalShares == 0) {
            deltaShares = _amount;
        } else {
            deltaShares = (_amount.mul(totalShares)).div(_pool);
        }

        totalShares = totalShares.add(deltaShares);
        _shares[_to] = _shares[_to].add(deltaShares);
        _principal[_to] = _principal[_to].add(_amount);
        _depositedAt[_to] = block.timestamp;

        IKSLP(address(_stakingToken)).claimReward();

        emit Deposited(_to, _amount);
    }

    function _cleanupIfDustShares() private {
        uint shares = _shares[msg.sender];
        if (shares > 0 && shares < DUST) {
            totalShares = totalShares.sub(shares);
            delete _shares[msg.sender];
        }
    }

    function setZap(address _zap) public onlyOwner {
        zap = IZapKlayswap(_zap);
        KSP.safeApprove(address(zap), uint(-1));
    }

    function withdraw(uint256 _amount) public override onlyOwner {
        // DO NOTHING
    }
}
