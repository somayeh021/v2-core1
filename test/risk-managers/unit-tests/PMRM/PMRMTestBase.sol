pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import "src/risk-managers/PMRM.sol";
import "src/assets/CashAsset.sol";
import "src/SubAccounts.sol";
import "src/interfaces/IManager.sol";
import "src/interfaces/IAsset.sol";
import "src/interfaces/ISubAccounts.sol";

import "test/shared/mocks/MockManager.sol";
import "test/shared/mocks/MockERC20.sol";
import "test/shared/mocks/MockAsset.sol";
import "test/shared/mocks/MockOption.sol";
import "test/shared/mocks/MockSM.sol";
import "test/shared/mocks/MockFeeds.sol";
import "test/auction/mocks/MockCashAsset.sol";

import "test/risk-managers/mocks/MockDutchAuction.sol";
import "test/shared/utils/JsonMechIO.sol";

import "forge-std/console2.sol";
import "../../../shared/mocks/MockFeeds.sol";
import "../../../../src/assets/WrappedERC20Asset.sol";
import "../../../shared/mocks/MockPerp.sol";
import "../../../../src/feeds/OptionPricing.sol";
import "./PMRMPublic.sol";

contract PMRMTestBase is JsonMechIO {
  using stdJson for string;

  SubAccounts subAccounts;
  PMRMPublic pmrm;
  MockCash cash;
  MockERC20 usdc;
  MockERC20 weth;
  WrappedERC20Asset baseAsset;

  MockOption option;
  MockDutchAuction auction;
  MockSM sm;
  MockFeeds feed;
  MockFeeds perpFeed;
  MockFeeds stableFeed;
  uint feeRecipient;
  OptionPricing optionPricing;
  MockPerp mockPerp;

  address alice = address(0xaa);
  address bob = address(0xbb);
  uint aliceAcc;
  uint bobAcc;

  function setUp() public virtual {
    vm.warp(1640995200); // 1st jan 2022

    subAccounts = new SubAccounts("Lyra Margin Accounts", "LyraMarginNFTs");

    feed = new MockFeeds();
    perpFeed = new MockFeeds();
    stableFeed = new MockFeeds();
    feed.setSpot(1500e18, 1e18);
    stableFeed.setSpot(1e18, 1e18);
    perpFeed.setSpot(1500e18, 1e18);

    usdc = new MockERC20("USDC", "USDC");
    weth = new MockERC20("weth", "weth");
    cash = new MockCash(usdc, subAccounts);
    baseAsset = new WrappedERC20Asset(subAccounts, weth);
    mockPerp = new MockPerp(subAccounts);

    option = new MockOption(subAccounts);
    optionPricing = new OptionPricing();

    pmrm = new PMRMPublic(
      subAccounts,
      cash,
      option,
      mockPerp,
      IOptionPricing(optionPricing),
      baseAsset,
      IDutchAuction(address(0)),
      IPMRM.Feeds({
        spotFeed: ISpotFeed(feed),
        perpFeed: ISpotFeed(perpFeed),
        stableFeed: ISpotFeed(stableFeed),
        forwardFeed: IForwardFeed(feed),
        interestRateFeed: IInterestRateFeed(feed),
        volFeed: IVolFeed(feed),
        settlementFeed: ISettlementFeed(feed)
      })
    );

    _setupAliceAndBob();
    addScenarios();

    feeRecipient = subAccounts.createAccount(address(this), pmrm);
    pmrm.setFeeRecipient(feeRecipient);
  }

  function _logPortfolio(IPMRM.Portfolio memory portfolio) internal view {
    console2.log("cash balance:", portfolio.cash);
    console2.log("\nOTHER ASSETS");
    console2.log("TODO");
    //    console2.log("count:", uint(portfolio.otherAssets.length));
    //    for (uint i = 0; i < portfolio.otherAssets.length; i++) {
    //      console2.log("- asset:", portfolio.otherAssets[i].asset);
    //      console2.log("- balance:", portfolio.otherAssets[i].amount);
    //      console2.log("----");
    //    }

    console2.log("spotPrice", portfolio.spotPrice);
    console2.log("stablePrice", portfolio.stablePrice);
    console2.log("cash", portfolio.cash);
    console2.log("perpPosition", portfolio.perpPosition);
    console2.log("basePosition", portfolio.basePosition);
    console2.log("baseValue", portfolio.baseValue);
    console2.log("totalMtM", portfolio.totalMtM);
    console2.log("fwdContingency", portfolio.fwdContingency);
    console2.log("staticContingency", portfolio.staticContingency);
    console2.log("confidenceContingency", portfolio.confidenceContingency);

    console2.log("\n");
    console2.log("expiryLen", uint(portfolio.expiries.length));
    console2.log("==========");
    console2.log();
    for (uint i = 0; i < portfolio.expiries.length; i++) {
      PMRM.ExpiryHoldings memory expiry = portfolio.expiries[i];
      console2.log("=== secToExpiry:", expiry.secToExpiry);
      console2.log("params:");

      console2.log("forwardFixedPortion", expiry.forwardFixedPortion);
      console2.log("forwardVariablePortion", expiry.forwardVariablePortion);
      console2.log("volShockUp", expiry.volShockUp);
      console2.log("volShockDown", expiry.volShockDown);
      console2.log("mtm", expiry.mtm);
      console2.log("fwdShock1MtM", expiry.fwdShock1MtM);
      console2.log("fwdShock2MtM", expiry.fwdShock2MtM);
      console2.log("staticDiscount", expiry.staticDiscount);
      console2.log("minConfidence", expiry.minConfidence);

      for (uint j = 0; j < expiry.options.length; j++) {
        console2.log(expiry.options[j].isCall ? "- CALL" : "- PUT");
        console2.log("- strike:", expiry.options[j].strike / 1e18);
        console2.log("- amount:", expiry.options[j].amount / 1e18);
      }
    }
  }

  function addScenarios() internal {
    // Scenario Number	Spot Shock (of max)	Vol Shock (of max)

    IPMRM.Scenario[] memory scenarios = new IPMRM.Scenario[](21);

    // add these 27 scenarios to the array
    scenarios[0] = IPMRM.Scenario({spotShock: 1.15e18, volShock: IPMRM.VolShockDirection.Up});
    scenarios[1] = IPMRM.Scenario({spotShock: 1.15e18, volShock: IPMRM.VolShockDirection.None});
    scenarios[2] = IPMRM.Scenario({spotShock: 1.15e18, volShock: IPMRM.VolShockDirection.Down});
    scenarios[3] = IPMRM.Scenario({spotShock: 1.1e18, volShock: IPMRM.VolShockDirection.Up});
    scenarios[4] = IPMRM.Scenario({spotShock: 1.1e18, volShock: IPMRM.VolShockDirection.None});
    scenarios[5] = IPMRM.Scenario({spotShock: 1.1e18, volShock: IPMRM.VolShockDirection.Down});
    scenarios[6] = IPMRM.Scenario({spotShock: 1.05e18, volShock: IPMRM.VolShockDirection.Up});
    scenarios[7] = IPMRM.Scenario({spotShock: 1.05e18, volShock: IPMRM.VolShockDirection.None});
    scenarios[8] = IPMRM.Scenario({spotShock: 1.05e18, volShock: IPMRM.VolShockDirection.Down});
    scenarios[9] = IPMRM.Scenario({spotShock: 1e18, volShock: IPMRM.VolShockDirection.Up});
    scenarios[10] = IPMRM.Scenario({spotShock: 1e18, volShock: IPMRM.VolShockDirection.None});
    scenarios[11] = IPMRM.Scenario({spotShock: 1e18, volShock: IPMRM.VolShockDirection.Down});
    scenarios[12] = IPMRM.Scenario({spotShock: 0.95e18, volShock: IPMRM.VolShockDirection.Up});
    scenarios[13] = IPMRM.Scenario({spotShock: 0.95e18, volShock: IPMRM.VolShockDirection.None});
    scenarios[14] = IPMRM.Scenario({spotShock: 0.95e18, volShock: IPMRM.VolShockDirection.Down});
    scenarios[15] = IPMRM.Scenario({spotShock: 0.9e18, volShock: IPMRM.VolShockDirection.Up});
    scenarios[16] = IPMRM.Scenario({spotShock: 0.9e18, volShock: IPMRM.VolShockDirection.None});
    scenarios[17] = IPMRM.Scenario({spotShock: 0.9e18, volShock: IPMRM.VolShockDirection.Down});
    scenarios[18] = IPMRM.Scenario({spotShock: 0.85e18, volShock: IPMRM.VolShockDirection.Up});
    scenarios[19] = IPMRM.Scenario({spotShock: 0.85e18, volShock: IPMRM.VolShockDirection.None});
    scenarios[20] = IPMRM.Scenario({spotShock: 0.85e18, volShock: IPMRM.VolShockDirection.Down});

    pmrm.setScenarios(scenarios);
  }

  function _setupAliceAndBob() internal {
    vm.label(alice, "alice");
    vm.label(bob, "bob");

    aliceAcc = subAccounts.createAccount(alice, IManager(address(pmrm)));
    bobAcc = subAccounts.createAccount(bob, IManager(address(pmrm)));

    // allow this contract to submit trades
    vm.prank(alice);
    subAccounts.setApprovalForAll(address(this), true);
    vm.prank(bob);
    subAccounts.setApprovalForAll(address(this), true);
  }

  function _depositCash(uint accId, uint amount) internal {
    usdc.mint(address(this), amount);
    usdc.approve(address(cash), amount);
    cash.deposit(accId, amount);
  }

  struct OptionData {
    uint secToExpiry;
    uint strike;
    bool isCall;
    int amount;
    uint vol;
    uint volConfidence;
  }

  struct OtherAssets {
    uint count;
    int cashAmount;
    int perpAmount;
    uint baseAmount;
  }

  struct FeedData {
    uint spotPrice;
    uint spotConfidence;
    uint stablePrice;
    uint stableConfidence;
    uint[] expiries;
    uint[] forwards;
    uint[] forwardConfidences;
    int[] rates;
    uint[] rateConfidences;
  }

  function readOptionData(string memory json, string memory testId) internal pure returns (OptionData[] memory) {
    uint[] memory expiries = json.readUintArray(string.concat(testId, ".OptionExpiries"));
    uint[] memory strikes = json.readUintArray(string.concat(testId, ".OptionStrikes"));
    uint[] memory isCall = json.readUintArray(string.concat(testId, ".OptionIsCall"));
    int[] memory amounts = json.readIntArray(string.concat(testId, ".OptionAmounts"));
    uint[] memory vols = json.readUintArray(string.concat(testId, ".OptionVols"));
    uint[] memory confidences = json.readUintArray(string.concat(testId, ".OptionVolConfidences"));

    OptionData[] memory data = new OptionData[](expiries.length);

    require(expiries.length == strikes.length, "strikes length mismatch");
    require(expiries.length == isCall.length, "isCall length mismatch");
    require(expiries.length == amounts.length, "amounts length mismatch");
    require(expiries.length == vols.length, "vols length mismatch");
    require(expiries.length == confidences.length, "confidences length mismatch");

    for (uint i = 0; i < expiries.length; ++i) {
      data[i] = OptionData({
        secToExpiry: expiries[i],
        strike: strikes[i],
        isCall: isCall[i] == 1,
        amount: amounts[i],
        vol: vols[i],
        volConfidence: confidences[i]
      });
    }

    return data;
  }

  function readOtherAssetData(string memory json, string memory testId) internal pure returns (OtherAssets memory) {
    uint count = 0;
    int cashAmount = json.readInt(string.concat(testId, ".Cash"));
    if (cashAmount != 0) {
      count++;
    }
    int perpAmount = json.readInt(string.concat(testId, ".Perps"));
    if (perpAmount != 0) {
      count++;
    }
    uint baseAmount = json.readUint(string.concat(testId, ".Base"));
    if (baseAmount != 0) {
      count++;
    }

    return OtherAssets({count: count, cashAmount: cashAmount, perpAmount: perpAmount, baseAmount: baseAmount});
  }

  function readFeedData(string memory json, string memory testId) internal pure returns (FeedData memory) {
    uint spotPrice = json.readUint(string.concat(testId, ".SpotPrice"));
    uint spotConfidence = json.readUint(string.concat(testId, ".SpotConfidence"));
    uint stablePrice = json.readUint(string.concat(testId, ".StablePrice"));
    uint stableConfidence = json.readUint(string.concat(testId, ".StableConfidence"));
    uint[] memory expiries = json.readUintArray(string.concat(testId, ".FeedExpiries"));
    uint[] memory forwards = json.readUintArray(string.concat(testId, ".Forwards"));
    uint[] memory forwardConfidences = json.readUintArray(string.concat(testId, ".ForwardConfidences"));
    int[] memory rates = json.readIntArray(string.concat(testId, ".Rates"));
    uint[] memory rateConfidences = json.readUintArray(string.concat(testId, ".RateConfidences"));

    require(expiries.length == forwards.length, "forwards length mismatch");
    require(expiries.length == forwardConfidences.length, "forwardConfidences length mismatch");
    require(expiries.length == rates.length, "rates length mismatch");
    require(expiries.length == rateConfidences.length, "rateConfidences length mismatch");

    return FeedData({
      spotPrice: spotPrice,
      spotConfidence: spotConfidence,
      stablePrice: stablePrice,
      stableConfidence: stableConfidence,
      expiries: expiries,
      forwards: forwards,
      forwardConfidences: forwardConfidences,
      rates: rates,
      rateConfidences: rateConfidences
    });
  }

  function setupTestScenarioAndGetAssetBalances(string memory testId)
    internal
    returns (ISubAccounts.AssetBalance[] memory balances)
  {
    uint referenceTime = block.timestamp;
    string memory json = JsonMechIO.jsonFromRelPath("/test/risk-managers/unit-tests/PMRM/testScenarios.json");

    FeedData memory feedData = readFeedData(json, testId);
    OptionData[] memory optionData = readOptionData(json, testId);
    OtherAssets memory otherAssets = readOtherAssetData(json, testId);

    /// Set feed values
    feed.setSpot(feedData.spotPrice, feedData.spotConfidence);
    for (uint i = 0; i < feedData.expiries.length; i++) {
      uint expiry = referenceTime + uint(feedData.expiries[i]);
      feed.setForwardPrice(expiry, feedData.forwards[i], feedData.forwardConfidences[i]);
      feed.setInterestRate(expiry, int64(feedData.rates[i]), uint64(feedData.rateConfidences[i]));
    }

    stableFeed.setSpot(feedData.stablePrice, feedData.stableConfidence);

    /// Get assets for user

    uint totalAssets = optionData.length + otherAssets.count;

    balances = new ISubAccounts.AssetBalance[](totalAssets);

    for (uint i = 0; i < optionData.length; ++i) {
      uint expiry = referenceTime + uint(optionData[i].secToExpiry);
      balances[i] = ISubAccounts.AssetBalance({
        asset: IAsset(option),
        subId: OptionEncoding.toSubId(expiry, uint(optionData[i].strike), optionData[i].isCall),
        balance: optionData[i].amount
      });

      feed.setVol(
        uint64(expiry), uint128(optionData[i].strike), uint128(optionData[i].vol), uint64(optionData[i].volConfidence)
      );
    }

    if (otherAssets.cashAmount != 0) {
      balances[balances.length - otherAssets.count--] =
        ISubAccounts.AssetBalance({asset: IAsset(address(cash)), subId: 0, balance: otherAssets.cashAmount});
    }
    if (otherAssets.perpAmount != 0) {
      balances[balances.length - otherAssets.count--] =
        ISubAccounts.AssetBalance({asset: IAsset(address(mockPerp)), subId: 0, balance: otherAssets.perpAmount});
    }
    if (otherAssets.baseAmount != 0) {
      balances[balances.length - otherAssets.count--] =
        ISubAccounts.AssetBalance({asset: IAsset(address(baseAsset)), subId: 0, balance: int(otherAssets.baseAmount)});
    }
    return balances;
  }

  function _doBalanceTransfer(uint accA, uint accB, ISubAccounts.AssetBalance[] memory balances) internal {
    subAccounts.submitTransfers(_getTransferBatch(accA, accB, balances), "");
  }

  function _getTransferBatch(uint accA, uint accB, ISubAccounts.AssetBalance[] memory balances)
    internal
    pure
    returns (ISubAccounts.AssetTransfer[] memory)
  {
    ISubAccounts.AssetTransfer[] memory transferBatch = new ISubAccounts.AssetTransfer[](balances.length);

    for (uint i = 0; i < balances.length; i++) {
      transferBatch[i] = ISubAccounts.AssetTransfer({
        fromAcc: accA,
        toAcc: accB,
        asset: balances[i].asset,
        subId: balances[i].subId,
        amount: balances[i].balance,
        assetData: bytes32(0)
      });
    }

    return transferBatch;
  }

  function _getCashBalance(uint acc) public view returns (int) {
    return subAccounts.getBalance(acc, cash, 0);
  }
}
