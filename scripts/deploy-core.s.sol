// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import "../src/assets/CashAsset.sol";
import "../src/assets/InterestRateModel.sol";
import "../src/liquidation/DutchAuction.sol";
import "../src/SubAccounts.sol";
import "../src/SecurityModule.sol";
import "../src/risk-managers/StandardManager.sol";
import "../src/risk-managers/SRMPortfolioViewer.sol";

import "../src/feeds/LyraSpotFeed.sol";

import "../test/shared/mocks/MockFeeds.sol";

import "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import "forge-std/console2.sol";
import {Deployment, ConfigJson} from "./types.sol";
import {Utils} from "./utils.sol";

// get all default params
import "./config.sol";


contract DeployCore is Utils {

  /// @dev main function
  function run() external {

    uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
    vm.startBroadcast(deployerPrivateKey);

    address deployer = vm.addr(deployerPrivateKey);
    console2.log("Start deploying core contracts! deployer: ", deployer);

    // load configs
    ConfigJson memory config = _loadConfig();

    // deploy core contracts
    _deployCoreContracts(deployer, config);

    vm.stopBroadcast();
  }


  /// @dev deploy and initiate contracts
  function _deployCoreContracts(address deployer, ConfigJson memory config) internal returns (Deployment memory deployment)  {

    uint nonce = vm.getNonce(deployer);

    // nonce: nonce
    deployment.subAccounts = new SubAccounts("Lyra Margin Accounts", "LyraMarginNFTs");
    
    (uint minRate, uint rateMultiplier, uint highRateMultiplier, uint optimalUtil) = getDefaultInterestRateModel();
    // nonce + 1
    deployment.rateModel = new InterestRateModel(minRate, rateMultiplier, highRateMultiplier, optimalUtil);

    // nonce + 2
    deployment.cash = new CashAsset(deployment.subAccounts, IERC20Metadata(config.usdc), deployment.rateModel);

    // nonce + 3: Deploy SM
    address srmAddr = computeCreateAddress(deployer, nonce + 6);
    console2.log("predicted addr", srmAddr);
    deployment.securityModule = new SecurityModule(deployment.subAccounts, deployment.cash, IManager(srmAddr));

    // nonce + 4: Deploy Auction
    deployment.auction = new DutchAuction(deployment.subAccounts, deployment.securityModule, deployment.cash);

    // nonce + 5: Deploy Viewer
    deployment.srmViewer = new SRMPortfolioViewer(deployment.subAccounts, deployment.cash);

    // nonce + 6: Deploy Standard Manager. Shared by all assets
    deployment.srm = new StandardManager(deployment.subAccounts, deployment.cash, deployment.auction, deployment.srmViewer);

    assert(address(deployment.srm) == address(srmAddr));

    // Deploy USDC stable feed
    if (config.useMockedFeed) {
      MockFeeds stableFeed = new MockFeeds();
      stableFeed.setSpot(1e18, 1e18);
      deployment.stableFeed = stableFeed;
    } else {
      LyraSpotFeed stableFeed = new LyraSpotFeed();
      stableFeed.setHeartbeat(365 days);
      deployment.stableFeed = stableFeed;
    }

    _setupCoreFunctions(deployment);

    // write to output
    __writeToDeploymentsJson(deployment);
  }

  function _setupCoreFunctions(Deployment memory deployment) internal {
    deployment.srmViewer.setStandardManager(deployment.srm);

    // setup cash
    deployment.cash.setLiquidationModule(deployment.auction);
    deployment.cash.setSmFeeRecipient(deployment.securityModule.accountId());

    // set parameter for auction
    deployment.auction.setSolventAuctionParams(getDefaultAuctionParam());
    deployment.auction.setInsolventAuctionParams(getDefaultInsolventAuctionParam());

    // allow liquidation to request payout from sm
    deployment.securityModule.setWhitelistModule(address(deployment.auction), true);

    deployment.cash.setWhitelistManager(address(deployment.srm), true);

    // global setting for SRM
    deployment.srm.setStableFeed(deployment.stableFeed);
    deployment.srm.setDepegParameters(IStandardManager.DepegParams(0.98e18, 1.2e18));

    console2.log("Core contracts deployed and setup!");
  }

  /**
   * @dev write to deployments/{network}/core.json
   */
  function __writeToDeploymentsJson(Deployment memory deployment) internal {

    string memory objKey = "core-deployments";

    vm.serializeAddress(objKey, "subAccounts", address(deployment.subAccounts));
    vm.serializeAddress(objKey, "cash", address(deployment.cash));
    vm.serializeAddress(objKey, "rateModel", address(deployment.rateModel));
    vm.serializeAddress(objKey, "securityModule", address(deployment.securityModule));
    vm.serializeAddress(objKey, "auction", address(deployment.auction));
    vm.serializeAddress(objKey, "srm", address(deployment.srm));
    vm.serializeAddress(objKey, "srmViewer", address(deployment.srmViewer));
    string memory finalObj = vm.serializeAddress(objKey, "stableFeed", address(deployment.stableFeed));

    // build path
    _writeToDeployments("core", finalObj);
  }

}