# TODO: Add tests here that show the normal operation of this strategy
#       Suggestions to include:
#           - strategy loading and unloading (via Vault addStrategy/revokeStrategy)
#           - change in loading (from low to high and high to low)
#           - strategy operation at different loading levels (anticipated and "extreme")
import pytest
import time
from brownie import Wei, accounts, Contract, config, interface, chain
from brownie import StratYvBOOSTPickle, MMVaultV3, ControllerV3

@pytest.fixture
def mmDeployer(accounts):
    yield accounts.at("0x43229759E12eFbe3e2A0fB0510B15e516d046442", force=True)
    
@pytest.fixture
def mmTimelock(accounts):
    yield accounts.at("0x5DAe9B27313670663B34Ac8BfFD18825bB9Df736", force=True)
    
@pytest.fixture
def yveCRVWhale(accounts):
    yield accounts.at("0x25431341a5800759268a6ac1d3cd91c029d7d9ca", force=True)
   
@pytest.fixture
def yveCRVToken(interface):
    yield interface.IERC20("0xc5bDdf9843308380375a611c18B50Fb9341f502A")
   
@pytest.fixture
def mmController(pm, mmDeployer):
    mmController = mmDeployer.deploy(ControllerV3, mmDeployer, mmDeployer, mmDeployer, mmDeployer, mmDeployer)
    #mmController = interface.MMController("0x4bf5059065541a2b176500928e91fbfd0b121d07")
    yield mmController
   
@pytest.fixture
def yveCRVVault(pm, yveCRVToken, mmDeployer, mmController):
    yveCRVVault = mmDeployer.deploy(MMVaultV3, yveCRVToken, mmDeployer, mmDeployer, mmController)
    #yveCRVVault = interface.MMVault("0xe28b1d0d667824e74b408a02c101cf0c0652d2ea")
    
    if(mmController.vaults(yveCRVToken) == "0x0000000000000000000000000000000000000000"):    
       mmController.setVault(yveCRVToken, yveCRVVault, {"from": mmDeployer})
    
    yield yveCRVVault
 
@pytest.fixture
def yveCRVStrategy(pm, yveCRVToken, mmDeployer, mmController, mmTimelock):
    yveCRVStrategy = mmDeployer.deploy(StratYvBOOSTPickle, yveCRVToken, mmDeployer, mmDeployer, mmController, mmDeployer)
    #yveCRVStrategy = interface.MMStrategy("0xbb924bc59Bb33ce68e1FD1a6c99e26Aa05d695c2")   
    mmController.approveStrategy(yveCRVToken, yveCRVStrategy, {"from": mmDeployer}) 
    #mmController.approveStrategy(yveCRVToken, yveCRVStrategy, {"from": mmTimelock}) 
    mmController.setStrategy(yveCRVToken, yveCRVStrategy, {"from": mmDeployer})
    yveCRVStrategy.setBuybackEnabled(False, {"from": mmDeployer})
    yveCRVStrategy.setDelayBlockRequired(False, {"from": mmDeployer})
    yield yveCRVStrategy
    
@pytest.mark.require_network("mainnet-fork")
def test_normal_flow(pm, mmDeployer, yveCRVWhale, yveCRVToken, yveCRVVault, yveCRVStrategy):
         
    # store original balance to compare
    prevBal = yveCRVToken.balanceOf(yveCRVWhale) 
    
    # deposit -> harvest    
    amount = 200_000 * 1e18
    _depositAndHarvest(mmDeployer, yveCRVWhale, yveCRVToken, yveCRVVault, yveCRVStrategy, amount)
    
    # Aha, we got vault appreciation by yielding $PICKLE!
    assert yveCRVStrategy.lastHarvestInWant() > 0 
    
    # withdraw  
    _wantTokenBefore = yveCRVToken.balanceOf(yveCRVWhale)  
    shareDivisor = 2
    _withdraw(yveCRVWhale, yveCRVVault, shareDivisor)  
    _wantTokenAfter = yveCRVToken.balanceOf(yveCRVWhale) 
    
    # we should have made some profit ignoring the fee
    assert (_wantTokenAfter - _wantTokenBefore) > _deduct_fee(amount / shareDivisor)
    
    # withdraw all rest 
    _withdraw(yveCRVWhale, yveCRVVault, 1)
    assert yveCRVVault.totalSupply() == 0
    
    # deposit again
    yveCRVVault.deposit(amount, {"from": yveCRVWhale})     
    assert yveCRVVault.balanceOf(yveCRVWhale) == amount
    
    
@pytest.mark.require_network("mainnet-fork")
def test_withdraw_all(pm, mmDeployer, yveCRVWhale, yveCRVToken, yveCRVVault, yveCRVStrategy, mmController):
         
    # store original balance to compare
    prevBal = yveCRVToken.balanceOf(yveCRVWhale) 
    
    # deposit -> harvest   
    amount = 200_000 * 1e18
    _depositAndHarvest(mmDeployer, yveCRVWhale, yveCRVToken, yveCRVVault, yveCRVStrategy, amount)
    
    # Aha, we got vault appreciation by yielding $PICKLE!
    assert yveCRVStrategy.lastHarvestInWant() > 0 
    
    # withdraw all from strategy  
    mmController.withdrawAll(yveCRVToken, {"from": mmDeployer})  
    # rough estimate wrt sushi swapping fee during LP creation
    assert yveCRVToken.balanceOf(yveCRVVault) >= (amount * 0.997)


####################### test dependent functions ########################################

def _reserve_mushrooms_vault(amount):
    # there is a reserve buffer in Mushrooms vaults
    return amount * 0.05

def _deduct_fee(amount):
    # deduct the withdraw fee (0.2% = 20 BPS) from yvboost vaults and swapping fee in sushiswap
    return amount * 0.998 * 0.997
 
def _depositAndHarvest(mmDeployer, yveCRVWhale, yveCRVToken, yveCRVVault, yveCRVStrategy, depositAmount):
    yveCRVToken.approve(yveCRVVault, 1000_000_000_000 * 1e18, {"from": yveCRVWhale})
    
    yveCRVVault.deposit(depositAmount, {"from": yveCRVWhale})     
    assert yveCRVVault.balanceOf(yveCRVWhale) == depositAmount
    
    bal = yveCRVToken.balanceOf(yveCRVVault)
    yveCRVVault.earn({"from": mmDeployer})   
    assert yveCRVToken.balanceOf(yveCRVVault) <= _reserve_mushrooms_vault(bal)  

    endMineTime = (int)(time.time() + 3600 * 1) # mine to 1 hour
    chain.mine(blocks=200, timestamp=endMineTime) 
    
    claimable = yveCRVStrategy.getHarvestable.call({"from": mmDeployer})
    assert claimable > 0
    
    yveCRVStrategy.harvest({"from": mmDeployer}) 

def _withdraw(yveCRVWhale, yveCRVVault, shareDivisor):
    shareAmount = yveCRVVault.balanceOf(yveCRVWhale)
    yveCRVVault.withdraw(shareAmount / shareDivisor, {"from": yveCRVWhale})     
    assert yveCRVVault.balanceOf(yveCRVWhale) == shareAmount - (shareAmount / shareDivisor)

