// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import "forge-std/Script.sol";

import "src/SubAccounts.sol";
import "test/shared/mocks/MockERC20.sol";
import "test/shared/mocks/MockAsset.sol";
import "test/shared/mocks/MockSM.sol";
import "../mocks/MockCashAsset.sol";
import "../mocks/MockLiquidatableManager.sol";
import "src/liquidation/DutchAuction.sol";

import "test/shared/mocks/MockFeeds.sol";

contract DutchAuctionBase is Test {
  address alice;
  address bob;
  address charlie;
  uint aliceAcc;
  uint bobAcc;
  uint charlieAcc;

  SubAccounts subAccounts;
  MockSM sm;
  MockERC20 usdc;
  MockCash usdcAsset;
  MockAsset optionAsset;
  MockLiquidatableManager manager;
  DutchAuction dutchAuction;

  function setUp() public {
    _deployMockSystem();
    _setupAccounts();

    dutchAuction = dutchAuction = new DutchAuction(subAccounts, sm, usdcAsset);

    dutchAuction.setSolventAuctionParams(_getDefaultSolventParams());
    dutchAuction.setInsolventAuctionParams(_getDefaultInsolventParams());

    dutchAuction.setBufferMarginPercentage(0.1e18);
  }

  /// @dev deploy mock system
  function _deployMockSystem() public {
    /* Base Layer */
    subAccounts = new SubAccounts("Lyra Margin Accounts", "LyraMarginNFTs");

    /* Wrappers */
    usdc = new MockERC20("usdc", "USDC");

    // usdc asset
    usdcAsset = new MockCash(usdc, subAccounts);

    // optionAsset: not allow deposit, can be negative
    optionAsset = new MockAsset(IERC20(address(0)), subAccounts, true);

    /* Risk Manager */
    manager = new MockLiquidatableManager(address(subAccounts));

    // mock cash
    sm = new MockSM(subAccounts, usdcAsset);
    sm.createAccountForSM(manager);
  }

  function _mintAndDeposit(
    address user,
    uint accountId,
    MockERC20 token,
    MockAsset assetWrapper,
    uint subId,
    uint amount
  ) public {
    token.mint(user, amount);

    vm.startPrank(user);
    token.approve(address(assetWrapper), type(uint).max);
    assetWrapper.deposit(accountId, subId, amount);
    vm.stopPrank();
  }

  function _setupAccounts() public {
    alice = address(0xaa);
    bob = address(0xbb);
    charlie = address(0xcc);
    usdc.approve(address(usdcAsset), type(uint).max);

    aliceAcc = subAccounts.createAccount(alice, manager);
    bobAcc = subAccounts.createAccount(bob, manager);
    charlieAcc = subAccounts.createAccount(charlie, manager);
  }

  //////////////////////////
  ///       Helpers      ///
  //////////////////////////

  function _getDefaultSolventParams() internal pure returns (IDutchAuction.SolventAuctionParams memory) {
    return IDutchAuction.SolventAuctionParams({
      startingMtMPercentage: 1e18,
      fastAuctionCutoffPercentage: 0.8e18,
      fastAuctionLength: 600,
      slowAuctionLength: 7200,
      liquidatorFeeRate: 0
    });
  }

  function _getDefaultInsolventParams() internal pure returns (IDutchAuction.InsolventAuctionParams memory) {
    return IDutchAuction.InsolventAuctionParams({totalSteps: 100, coolDown: 5, bufferMarginScalar: 1.2e18});
  }
}