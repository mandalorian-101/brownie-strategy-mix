// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

interface IUni{
    function getAmountsOut(
        uint256 amountIn, 
        address[] calldata path
    ) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

import "../interfaces/Mushrooms.sol";

/**
 * @title Strategy for Mushrooms WBTC vault/farming pool yield
 * @author Mushrooms Finance
 * @notice
 *  BaseStrategy implements all of the required functionality to interoperate
 *  closely with the Vault contract. This contract should be inherited and the
 *  abstract methods implemented to adapt the Strategy to the particular needs
 *  it has to create a return.
 *
 *  Of special interest is the relationship between `harvest()` and
 *  `vault.report()'. `harvest()` may be called simply because enough time has
 *  elapsed since the last report, and not because any funds need to be moved
 *  or positions adjusted. This is critical so that the Vault may maintain an
 *  accurate picture of the Strategy's performance. See  `vault.report()`,
 *  `harvest()`, and `harvestTrigger()` for further details.
 */
contract Strategy is BaseStrategy {
    
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
	
    address constant public wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599); //wbtc
    address constant public mm = address(0xa283aA7CfBB27EF0cfBcb2493dD9F4330E0fd304); //MM
    address public constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; //USDC
    address constant public unirouter = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address constant public sushiroute = address(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    address constant public weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); 

    address constant public mmVault = address(0xb06661A221Ab2Ec615531f9632D6Dc5D2984179A);// Mushrooms mWBTC vault
    address constant public mmFarmingPool = address(0xf8873a6080e8dbF41ADa900498DE0951074af577); //Mushrooms mining MasterChef
    uint256 constant public mmFarmingPoolId = 11; // Mushrooms farming pool id for mWBTC

    uint256 public minMMToSwap = 1; // min $MM to swap during adjustPosition()
    uint256 public minShareToProfit = 1; // min mWBTC share to withdraw as profit during prepareReturn()
	
    /**
     * @notice This Strategy's name.
     * @dev
     *  You can use this field to manage the "version" of this Strategy, e.g.
     *  `StrategySomethingOrOtherV1`. However, "API Version" is managed by
     *  `apiVersion()` function above.
     * @return This Strategy's name.
     */
    function name() external override view returns (string memory){
        return "StrategyMushroomsWBTCV1";
    }

    /**
     * @notice
     *  Initializes the Strategy, this is called only once, when the contract is deployed.
     * @dev `_vault` should implement `VaultAPI`.
     * @param _vault The address of the Vault responsible for this Strategy.
     */
    constructor(address _vault) BaseStrategy(_vault) public {
        require(address(want) == wbtc, '!wrongVault');				
        want.safeApprove(mmVault, uint256(-1));		
        IERC20(mmVault).safeApprove(mmFarmingPool, uint256(-1));
        IERC20(mm).safeApprove(unirouter, uint256(-1));
        IERC20(mm).safeApprove(sushiroute, uint256(-1));
    }    

    function setMinMMToSwap(uint256 _minMMToSwap) external onlyAuthorized {
        minMMToSwap = _minMMToSwap;
    }   

    function setMinShareToProfit(uint256 _minShareToProfit) external onlyAuthorized {
        minShareToProfit = _minShareToProfit;
    }
    
	/**
     * @notice
     *  The amount (priced in want) of the total assets managed by this strategy should not count
     *  towards Yearn's TVL calculations.
     * @dev
     *  You can override this field to set it to a non-zero value if some of the assets of this
     *  Strategy is somehow delegated inside another part of of Yearn's ecosystem e.g. another Vault.
     *  Note that this value must be strictly less than or equal to the amount provided by
     *  `estimatedTotalAssets()` below, as the TVL calc will be total assets minus delegated assets.
     * @return
     *  The amount of assets this strategy manages that should not be included in Yearn's Total Value
     *  Locked (TVL) calculation across it's ecosystem.
     */
    function delegatedAssets() external override view returns (uint256) {
        return 0;
    }
	
    /**
     * @notice
     *  Provide an accurate estimate for the total amount of assets
     *  (principle + return) that this Strategy is currently managing,
     *  denominated in terms of `want` tokens.
     *
     *  This total should be "realizable" e.g. the total value that could
     *  *actually* be obtained from this Strategy if it were to divest its
     *  entire position based on current on-chain conditions.
     * @dev
     *  Care must be taken in using this function, since it relies on external
     *  systems, which could be manipulated by the attacker to give an inflated
     *  (or reduced) value produced by this function, based on current on-chain
     *  conditions (e.g. this function is possible to influence through
     *  flashloan attacks, oracle manipulations, or other DeFi attack
     *  mechanisms).
     *
     *  It is up to governance to use this function to correctly order this
     *  Strategy relative to its peers in the withdrawal queue to minimize
     *  losses for the Vault based on sudden withdrawals. This value should be
     *  higher than the total debt of the Strategy and higher than its expected
     *  value to be "safe".
     * @return The estimated total assets in this Strategy.
     */
    function estimatedTotalAssets() public override view returns (uint256){
        (uint256 _mToken, ) = MMFarmingPool(mmFarmingPool).userInfo(mmFarmingPoolId, address(this));
        uint256 _mmVault = IERC20(mmVault).balanceOf(address(this));
        return _convertMTokenToWant(_mToken.add(_mmVault)).add(want.balanceOf(address(this)));
    }

    /**
     * Perform any Strategy unwinding or other calls necessary to capture the
     * "free return" this Strategy has generated since the last time its core
     * position(s) were adjusted. Examples include unwrapping extra rewards.
     * This call is only used during "normal operation" of a Strategy, and
     * should be optimized to minimize losses as much as possible.
     *
     * This method returns any realized profits and/or realized losses
     * incurred, and should return the total amounts of profits/losses/debt
     * payments (in `want` tokens) for the Vault's accounting (e.g.
     * `want.balanceOf(this) >= _debtPayment + _profit - _loss`).
     *
     * `_debtOutstanding` will be 0 if the Strategy is not past the configured
     * debt limit, otherwise its value will be how far past the debt limit
     * the Strategy is. The Strategy's debt limit is configured in the Vault.
     *
     * NOTE: `_debtPayment` should be less than or equal to `_debtOutstanding`.
     *       It is okay for it to be less than `_debtOutstanding`, as that
     *       should only used as a guide for how much is left to pay back.
     *       Payments should be made to minimize loss from slippage, debt,
     *       withdrawal fees, etc.
     *
     * See `vault.debtOutstanding()`.
     */
    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
    ){			
		
        // Pay debt if any
        if (_debtOutstanding > 0) {
            (uint256 _amountFreed, uint256 _reportLoss) = liquidatePosition(_debtOutstanding);
            _debtPayment = _amountFreed > _debtOutstanding? _debtOutstanding : _amountFreed;
            _loss = _reportLoss;
        }	
		
        // Capture some additional profit if underlying vault get appreciation
        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 currentValue = estimatedTotalAssets();
        if (currentValue > debt){
            uint256 target = currentValue.sub(debt);
            uint256 _beforeWant = want.balanceOf(address(this));
            uint256 _withdrawMShare = _convertWantToMToken(target);
            if (_withdrawMShare > minShareToProfit){
                uint256 _mmVault = IERC20(mmVault).balanceOf(address(this));
                if (_mmVault < _withdrawMShare){
                    _withdrawFromFarming(_withdrawMShare, _mmVault);
                }
                MMVault(mmVault).withdraw(_withdrawMShare);
                uint256 _afterWant = want.balanceOf(address(this));
                if (_afterWant > _beforeWant){
                    uint256 actual = _afterWant.sub(_beforeWant);
                    _profit = _profit.add(actual);
                    _loss = _loss.add(actual < target? target.sub(actual) : 0);
                }			
            }
        }		
		
        // Claim $MM profit
        uint256 _pendingMM = MMFarmingPool(mmFarmingPool).pendingMM(mmFarmingPoolId, address(this));
        if (_pendingMM > 0){
            MMFarmingPool(mmFarmingPool).withdraw(mmFarmingPoolId, 0);		
        }
        _profit = _profit.add(_disposeOfMM());
		
        // zero-out _profit & _loss
        if (_profit > _loss){
            _profit = _profit.sub(_loss);
            _loss = 0;
        } else{
            _loss = _loss.sub(_profit);
            _profit = 0;
        }
		
        return (_profit, _loss, _debtPayment);
    }

    /**
     * Perform any adjustments to the core position(s) of this Strategy given
     * what change the Vault made in the "investable capital" available to the
     * Strategy. Note that all "free capital" in the Strategy after the report
     * was made is available for reinvestment. Also note that this number
     * could be 0, and you should handle that scenario accordingly.
     *
     * See comments regarding `_debtOutstanding` on `prepareReturn()`.
     */
    function adjustPosition(uint256 _debtOutstanding) internal override{
	
        //emergency exit is dealt with in prepareReturn
        if (emergencyExit) {
            return;
        }
		
        uint256 _before = IERC20(mmVault).balanceOf(address(this));
        uint256 _after = _before;	
		
        uint256 _want = want.balanceOf(address(this));
        if (_want > _debtOutstanding) {
            _want = _want.sub(_debtOutstanding);
            
            MMVault(mmVault).deposit(_want);
            _after = IERC20(mmVault).balanceOf(address(this));
            require(_after > _before, '!mismatchDepositIntoMushrooms');
        } else if(_debtOutstanding > _want){
            return;		
        }		
								
        if (_after > 0){
            MMFarmingPool(mmFarmingPool).deposit(mmFarmingPoolId, _after);
        }		            
    }

    /**
     * Liquidate up to `_amountNeeded` of `want` of this strategy's positions,
     * irregardless of slippage. Any excess will be re-invested with `adjustPosition()`.
     * This function should return the amount of `want` tokens made available by the
     * liquidation. If there is a difference between them, `_loss` indicates whether the
     * difference is due to a realized loss, or if there is some other sitution at play
     * (e.g. locked funds). This function is used during emergency exit instead of
     * `prepareReturn()` to liquidate all of the Strategy's positions back to the Vault.
     *
     * NOTE: The invariant `_liquidatedAmount + _loss <= _amountNeeded` should always be maintained
     */
    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
		
        bool liquidateAll = _amountNeeded >= estimatedTotalAssets()? true : false;
        
        if (liquidateAll){ 	
            (uint256 _mToken, ) = MMFarmingPool(mmFarmingPool).userInfo(mmFarmingPoolId, address(this));
            MMFarmingPool(mmFarmingPool).withdraw(mmFarmingPoolId, _mToken);
            MMVault(mmVault).withdraw(IERC20(mmVault).balanceOf(address(this)));
            _liquidatedAmount = IERC20(want).balanceOf(address(this));
            uint256 ttDebt = vault.strategies(address(this)).totalDebt;
            uint256 _liquidateAllLoss = 0;
            if (_liquidatedAmount < ttDebt){
               _liquidateAllLoss = ttDebt.sub(_liquidatedAmount);
            }
            return (_liquidatedAmount, _liquidateAllLoss);		  
        } else{ 	
            uint256 _before = IERC20(want).balanceOf(address(this));
            if (_before < _amountNeeded){            
               uint256 _gap = _amountNeeded.sub(_before);	
               uint256 _mShare = _convertWantToMToken(_gap);			
               
               uint256 _mmVault = IERC20(mmVault).balanceOf(address(this));
               if (_mmVault < _mShare){
                   _withdrawFromFarming(_mShare, _mmVault);
               }
               MMVault(mmVault).withdraw(_mShare);
               uint256 _after = IERC20(want).balanceOf(address(this));
               require(_after > _before, '!mismatchMushroomsVaultWithdraw');

               return (_after, _amountNeeded > _after? _amountNeeded.sub(_after): 0);		
            } else{
               return (_amountNeeded, _loss);
            }		
        }
    }
	
	/**
     * @notice
     *  Provide a signal to the keeper that `harvest()` should be called. The
     *  keeper will provide the estimated gas cost that they would pay to call
     *  `harvest()`, and this function should use that estimate to make a
     *  determination if calling it is "worth it" for the keeper. This is not
     *  the only consideration into issuing this trigger, for example if the
     *  position would be negatively affected if `harvest()` is not called
     *  shortly, then this can return `true` even if the keeper might be "at a
     *  loss" (keepers are always reimbursed by Yearn).
     * @dev
     *  `callCost` must be priced in terms of `want`.
     *
     *  This call and `tendTrigger` should never return `true` at the
     *  same time.
     *
     *  See `maxReportDelay`, `profitFactor`, `debtThreshold` to adjust the
     *  strategist-controlled parameters that will influence whether this call
     *  returns `true` or not. These parameters will be used in conjunction
     *  with the parameters reported to the Vault (see `params`) to determine
     *  if calling `harvest()` is merited.
     *
     *  It is expected that an external system will check `harvestTrigger()`.
     *  This could be a script run off a desktop or cloud bot (e.g.
     *  https://github.com/iearn-finance/yearn-vaults/blob/master/scripts/keep.py),
     *  or via an integration with the Keep3r network (e.g.
     *  https://github.com/Macarse/GenericKeep3rV2/blob/master/contracts/keep3r/GenericKeep3rV2.sol).
     * @param callCost The keeper's estimated cast cost to call `harvest()`.
     * @return `true` if `harvest()` should be called, `false` otherwise.
     */
    function harvestTrigger(uint256 callCost) public view override returns (bool) {
        return super.harvestTrigger(ethToWant(callCost));
    }

    /**
     * Do anything necessary to prepare this Strategy for migration, such as
     * transferring any reserve or LP tokens, CDPs, or other tokens or stores of
     * value.
     */
    function prepareMigration(address _newStrategy) internal override{
        (uint256 _mToken, ) = MMFarmingPool(mmFarmingPool).userInfo(mmFarmingPoolId, address(this));
        MMFarmingPool(mmFarmingPool).withdraw(mmFarmingPoolId, _mToken);
		
        uint256 _mmVault = IERC20(mmVault).balanceOf(address(this));
        if (_mmVault > 0){
            IERC20(mmVault).safeTransfer(_newStrategy, _mmVault);
        }
	    
        uint256 _mm = IERC20(mm).balanceOf(address(this));
        if (_mm > 0){
            IERC20(mm).safeTransfer(_newStrategy, _mm);
        }
    }

    /**
     * Override this to add all tokens/tokenized positions this contract
     * manages on a *persistent* basis (e.g. not just for swapping back to
     * want ephemerally).
     *
     * NOTE: Do *not* include `want`, already included in `sweep` below.
     *
     * Example:
     *
     *    function protectedTokens() internal override view returns (address[] memory) {
     *      address[] memory protected = new address[](3);
     *      protected[0] = tokenA;
     *      protected[1] = tokenB;
     *      protected[2] = tokenC;
     *      return protected;
     *    }
     */
    function protectedTokens() internal override view returns (address[] memory){
        address[] memory protected = new address[](1);
        protected[0] = mmVault;
        return protected;
    }
	
    function _convertMTokenToWant(uint256 _shares) internal view returns (uint256){
        uint256 _mTokenTotal = IERC20(mmVault).totalSupply();
        if (_mTokenTotal == 0){
            return 0;
        }
        uint256 _wantInVault = MMVault(mmVault).balance();
        return (_wantInVault.mul(_shares)).div(_mTokenTotal);
    }
	
    function _convertWantToMToken(uint256 _want) internal view returns (uint256){
        return _want.mul(1e18).div(MMVault(mmVault).getRatio());
    }	
	
    function _withdrawFromFarming(uint256 _target, uint256 _balance) internal {
        uint256 _mvGap = _target.sub(_balance); 			
        (uint256 _mToken, ) = MMFarmingPool(mmFarmingPool).userInfo(mmFarmingPoolId, address(this));
        require(_mToken >= _mvGap, '!insufficientMTokenInMasterChef');		
        MMFarmingPool(mmFarmingPool).withdraw(mmFarmingPoolId, _mvGap);	
    }
	
    // swap $MM for $WBTC
    function _disposeOfMM() internal returns (uint256){
        uint256 _mm = IERC20(mm).balanceOf(address(this));
        uint256 _wantProfit; 
		
        if (_mm >= minMMToSwap) {
            // intuitively in favor of sushiswap over uniswap if possible for better efficiency and cost
			
            address[] memory pathSushi = new address[](3);
            pathSushi[0] = mm;
            pathSushi[1] = weth;
            pathSushi[2] = wbtc;
            uint256 outputSushi = IUni(sushiroute).getAmountsOut(_mm, pathSushi)[pathSushi.length - 1];
						            
            address[] memory pathUni = new address[](4);
            pathUni[0] = mm;
            pathUni[1] = usdc;
            pathUni[2] = weth;
            pathUni[3] = wbtc;
            uint256 outputUni = IUni(unirouter).getAmountsOut(_mm, pathUni)[pathUni.length - 1];
			
            uint256 _want = want.balanceOf(address(this));
            if (outputSushi >= outputUni){
                IUni(sushiroute).swapExactTokensForTokens(_mm, uint256(0), pathSushi, address(this), now);			
            } else{
                IUni(unirouter).swapExactTokensForTokens(_mm, uint256(0), pathUni, address(this), now);			
            }
            _wantProfit = want.balanceOf(address(this)).sub(_want);
        }
        return _wantProfit;
    }
	
    function ethToWant(uint256 _amount) public view returns (uint256) {
        if (_amount == 0) {
            return 0;
        }

        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = wbtc;
        uint256[] memory amounts = IUni(unirouter).getAmountsOut(_amount, path);

        return amounts[amounts.length - 1];
    }
}
