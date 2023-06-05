// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IManager} from "src/interfaces/IManager.sol";
import {IPerpAsset} from "src/interfaces/IPerpAsset.sol";
import {IOption} from "src/interfaces/IOption.sol";

interface IStandardManager {
  enum AssetType {
    NotSet,
    Option,
    Perpetual,
    Base
  }

  struct AssetDetail {
    bool isWhitelisted;
    AssetType assetType;
    uint8 marketId;
  }

  /**
   * @dev a standard manager portfolio contains up to 5 marketHoldings assets
   * each marketHolding contains multiple derivative type
   */
  struct StandardManagerPortfolio {
    // @dev each marketHolding take care of 1 base asset, for example ETH and BTC.
    MarketHolding[] marketHoldings;
    int cash;
  }

  struct MarketHolding {
    uint8 marketId;
    // base position: doesn't contribute to margin, but increase total portfolio mark to market
    int basePosition;
    // perp position detail
    IPerpAsset perp;
    int perpPosition;
    // option position detail
    IOption option;
    ExpiryHolding[] expiryHoldings;
    /// sum of all short positions, abs(perps) and base positions.
    /// used to increase margin requirement if USDC depeg. Should be positive
    int depegPenaltyPos;
  }

  /// @dev contains portfolio struct for single expiry assets
  struct ExpiryHolding {
    /// expiry timestamp
    uint expiry;
    /// array of strike holding details
    Option[] options;
    /// sum of all call positions, used to determine if portfolio max loss is bounded
    int netCalls;
    /// temporary variable to count how many options is used
    uint numOptions;
    /// total short position size. should be positive
    int totalShortPositions;
  }

  struct Option {
    uint strike;
    int balance;
    bool isCall;
  }

  /// @dev Struct for Perp Margin Requirements
  struct PerpMarginRequirements {
    /// @dev minimum amount of spot required as maintenance margin for each perp position
    uint mmPerpReq;
    /// @dev minimum amount of spot required as initial margin for each perp position
    uint imPerpReq;
  }

  /// @dev Struct for Option Margin Parameters
  struct OptionMarginParams {
    /// @dev Percentage of spot to add to initial margin if option is ITM. Decreases as option becomes more OTM.
    int maxSpotReq;
    /// @dev Minimum amount of spot price to add as initial margin.
    int minSpotReq;
    /// @dev Minimum amount of spot price to add as maintenance margin.
    int mmCallSpotReq;
    /// @dev Minimum amount of spot to add for maintenance margin
    int mmPutSpotReq;
    /// @dev Minimum amount of mtm to add for maintenance margin for puts
    int MMPutMtMReq;
    /// @dev Scaler applied to forward by amount if max loss is unbounded, when calculating IM
    int unpairedIMScale;
    /// @dev Scaler applied to forward by amount if max loss is unbounded, when calculating MM
    int unpairedMMScale;
    /// @dev Scale the MM for a put as minimum of IM
    int mmOffsetScale;
  }

  struct DepegParams {
    int128 threshold;
    int128 depegFactor;
  }

  struct OracleContingencyParams {
    uint64 perpThreshold;
    uint64 optionThreshold;
    uint64 baseThreshold;
    int64 OCFactor;
  }

  ///////////////
  //   Errors  //
  ///////////////

  /// @dev Caller is not the Accounts contract
  error SRM_NotAccounts();

  /// @dev Not whitelist manager
  error SRM_NotWhitelistManager();

  /// @dev Not supported asset
  error SRM_UnsupportedAsset();

  /// @dev Account is under water, need more cash
  error SRM_PortfolioBelowMargin(uint accountId, int margin);

  /// @dev Invalid Parameters for perp margin requirements
  error SRM_InvalidPerpMarginParams();

  error SRM_InvalidOptionMarginParams();

  /// @dev Forward Price for an asset is 0
  error SRM_NoForwardPrice();

  /// @dev Invalid depeg parameters
  error SRM_InvalidDepegParams();

  /// @dev Invalid Oracle contingency params
  error SRM_InvalidOracleContingencyParams();

  /// @dev Invalid base asset margin discount factor
  error SRM_InvalidBaseDiscountFactor();

  /// @dev No negative cash
  error SRM_NoNegativeCash();

  ///////////////////
  //    Events     //
  ///////////////////

  event AssetWhitelisted(address asset, uint8 marketId, AssetType assetType);

  event OraclesSet(
    uint8 marketId, address spotOracle, address forwardOracle, address settlementOracle, address volFeed
  );

  event PricingModuleSet(uint8 marketId, address pricingModule);

  event PerpMarginRequirementsSet(uint8 marketId, uint perpMMRequirement, uint perpIMRequirement);

  event OptionMarginParamsSet(
    uint8 marketId,
    int maxSpotReq,
    int minSpotReq,
    int mmCallSpotReq,
    int mmPutSpotReq,
    int MMPutMtMReq,
    int unpairedIMScale,
    int unpairedMMScale,
    int mmOffsetScale
  );

  event BaseMarginDiscountFactorSet(uint8 marketId, uint baseMarginDiscountFactor);

  event DepegParametersSet(int128 threshold, int128 depegFactor);

  event OracleContingencySet(uint64 prepThreshold, uint64 optionThreshold, uint64 baseThreshold, int64 ocFactor);

  event StableFeedUpdated(address stableFeed);
}