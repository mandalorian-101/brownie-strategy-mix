// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;

interface MMVault {
    function token() external view returns (address);
    function getRatio() external view returns (uint256);
    function deposit(uint256) external;
    function withdraw(uint256) external;
    function withdrawAll() external;
    function earn() external;
    function balance() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address _user) external view returns (uint256);
    function addKeeper(address _keeper) external;
}

interface MMStrategy {
    function harvest() external;
    function setStrategist(address _strategist) external;
    function setBuybackEnabled(bool _enable) external;
    function leverageToMax() external;
    function deleverageToMin() external;
    function getBorrowedView() external view returns (uint256);
    function getSuppliedView() external view returns (uint256);
    function requiredPaidDebt(uint256 _redeemCollateralAmt) external view returns (uint256);
    function balanceOfPool() external view returns (uint256);
    function setDelayBlockRequired(uint256 _delayBlockRequired) external;
}

interface MMFarmingPool {
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    function userInfo(uint256, address) external view returns (uint256 amount, uint256 rewardDebt);
    function pendingMM(uint256 _pid, address _user) external view returns (uint256);
    function setBuybackNotifier(address _notifier, bool _enable) external;
}

interface MMController {
    function approveStrategy(address _token, address _strategy) external;
    function setStrategy(address _token, address _strategy) external;	
    function vaults(address _token) external view returns(address);
    function setVault(address _token, address _vault) external;
    function withdrawAll(address _token) external;
}

interface MMTimelock {
    function executeTransaction(address target, uint value, string memory signature, bytes memory data, uint eta) external payable returns (bytes memory);
}

interface MMGenericKp3r {
    function getStrategies() external view returns (address[] memory);
    function getCollateralizedStrategies() external view returns (address[] memory);
    function getVaults() external view returns (address[] memory);	
    function harvestable(address _strategy) external returns (bool);
    function harvest(address _strategy) external;
    function earnable(address _strategy) external view returns (bool);
    function earn(address _strategy) external;
    function keepMinRatioMayday(address _strategy) external view returns (bool);
    function keepMinRatio(address _strategy) external;
    function addStrategy(address _vault, address _strategy, uint256 _requiredHarvest, bool _requiredKeepMinRatio, bool _requiredLeverageToMax, address yieldToken, uint256 yieldTokenOracle) external;    
    function addVault(address _vault, uint256 _requiredEarnBalance) external;
    function removeHarvestStrategy(address _strategy) external;
    function removeEarnVault(address _vault) external;
    function setMinHarvestInterval(uint256 _interval) external;	
    function setProfitFactor(uint256 _profitFactor) external;
    function updateRequiredHarvestAmount(address _strategy, uint256 _requiredHarvest) external;    
    function updateYieldTokenOracle(address _strategy, uint256 _yieldTokenOracle) external;    
    function updateRequiredEarn(address _vault, uint256 _requiredEarnBalance) external;
}
