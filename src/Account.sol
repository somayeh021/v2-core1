pragma solidity ^0.8.13;

import "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import "./interfaces/IAbstractAsset.sol";
import "./interfaces/IAbstractManager.sol";
import "./interfaces/AccountStructs.sol";

import "forge-std/console2.sol";

contract Account is ERC721 {
  using SafeCast for int; // BalanceAndOrder.balance
  using SafeCast for uint; // BalanceAndOrder.order

  ///////////////
  // Variables //
  ///////////////

  uint nextId = 1;
  mapping(uint => IAbstractManager) manager;
  mapping(bytes32 => AccountStructs.BalanceAndOrder) public balanceAndOrder;
  mapping(uint => AccountStructs.HeldAsset[]) heldAssets;

  mapping(bytes32 => mapping(address => uint)) public positiveSubIdAllowance;
  mapping(bytes32 => mapping(address => uint)) public negativeSubIdAllowance;
  mapping(bytes32 => mapping(address => uint)) public positiveAssetAllowance;
  mapping(bytes32 => mapping(address => uint)) public negativeAssetAllowance;

  constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

  ///////////////////
  // Account Admin //
  ///////////////////

  function createAccount(address owner, IAbstractManager _manager) external returns (uint newId) {
    return _createAccount(owner, _manager);
  }

  function _createAccount(address owner, IAbstractManager _manager) internal returns (uint newId) {
    newId = ++nextId;
    manager[newId] = _manager;
    _mint(owner, newId);
    return newId;
  }

  /// @dev gas efficient method for migrating AMMs
  function changeManager(uint accountId, IAbstractManager newManager) external {
    require(_isApprovedOrOwner(msg.sender, accountId), "must be full delegate or owner");

    manager[accountId].handleManagerChange(accountId, manager[accountId], newManager);

    // only call to asset once 
    AccountStructs.HeldAsset[] memory accountAssets = heldAssets[accountId];
    IAbstractAsset[] memory seenAssets = new IAbstractAsset[](accountAssets.length);
    uint nextSeenId;

    for (uint i; i < accountAssets.length; ++i) {
      if (!_findInArray(seenAssets, accountAssets[i].asset)) {
        seenAssets[nextSeenId++] = accountAssets[i].asset;
      }
    }

    for (uint i; i < nextSeenId; ++i) {
      seenAssets[i].handleManagerChange(accountId, manager[accountId], newManager);
    }

    manager[accountId] = newManager;
    _managerCheck(accountId, msg.sender);
  }

  ///////////////
  // Approvals //
  ///////////////

  /// @dev blanket allowance over transfers, merges, splits, account transfers 
  ///      only one blanket delegate allowed
  function setFullAllowance(
    uint accountId,
    address delegate
  ) external {
    _approve(delegate, accountId);
  }

  /// @dev the sum of asset allowances + subId allowances is used during _allowanceCheck()
  ///      subId allowances are decremented before asset allowances
  ///      cannot merge with this type of allowance
  function setAssetAllowances(
    uint accountId, 
    address delegate, 
    IAbstractAsset[] memory assets,
    uint[] memory positiveAllowances,
    uint[] memory negativeAllowances
  ) external {
    require(_isApprovedOrOwner(msg.sender, accountId), "must be full delegate or owner");

    uint assetsLen = assets.length;
    for (uint i; i < assetsLen; i++) {
      bytes32 assetKey = _getEntryKey(accountId, assets[i], 0);
      positiveAssetAllowance[assetKey][delegate] = positiveAllowances[i];
      negativeAssetAllowance[assetKey][delegate] = negativeAllowances[i];
    }
  }

  function setSubIdAllowances(
    uint accountId, 
    address delegate, 
    IAbstractAsset[] memory assets,
    uint[] memory subIds,
    uint[] memory positiveAllowances,
    uint[] memory negativeAllowances
  ) external {
    require(_isApprovedOrOwner(msg.sender, accountId), "must be full delegate or owner");

    uint assetsLen = assets.length;
    for (uint i; i < assetsLen; i++) {
      bytes32 subIdKey = _getEntryKey(accountId, assets[i], subIds[i]);
      positiveSubIdAllowance[subIdKey][delegate] = positiveAllowances[i];
      negativeSubIdAllowance[subIdKey][delegate] = negativeAllowances[i];
    }
}

  /// @dev giving managers exclusive rights to transfer account ownerships
  function _isApprovedOrOwner(address spender, uint tokenId) internal view override returns (bool) {
    address owner = ERC721.ownerOf(tokenId);
    bool isManager = address(manager[tokenId]) == msg.sender;
    return (
      spender == owner || 
      isApprovedForAll(owner, spender) || 
      getApproved(tokenId) == spender || 
      isManager
    );
  }

  /////////////////////////
  // Balance Adjustments //
  /////////////////////////

  /// @dev Merges all accounts into first account and leaves remaining empty but not burned
  ///      This ensures accounts can be reused after being merged
  function merge(uint targetAccount, uint[] memory accountsToMerge) external {
    // does not use _allowanceCheck() for gas efficiency
    require(_isApprovedOrOwner(msg.sender, targetAccount), "must be full delegate or owner");

    uint mergingAccLen = accountsToMerge.length;
    for (uint i = 0; i < mergingAccLen; i++) {
      _transferAll(accountsToMerge[i], targetAccount);
      _managerCheck(accountsToMerge[i], msg.sender); // incase certain accounts cannot be emptied
    }

    _managerCheck(targetAccount, msg.sender);
  }

    /// @dev same as (1) create account (2) submit transfers [the `AssetTranfser.toAcc` field is overwritten]
  ///      msg.sender must be delegate approved to split
  function split(uint accountToSplitId, AccountStructs.AssetTransfer[] memory assetTransfers, address splitAccountOwner) external {
    uint newAccountId = _createAccount(msg.sender, manager[accountToSplitId]);

    uint transfersLen = assetTransfers.length;
    for (uint i; i < transfersLen; ++i) {
      assetTransfers[i].toAcc = newAccountId;
    }

    _submitTransfers(assetTransfers);

    if (splitAccountOwner != msg.sender) {
      transferFrom(msg.sender, splitAccountOwner, newAccountId);
    }
  }

  function submitTransfer(AccountStructs.AssetTransfer memory assetTransfer) external {
    _transferAsset(assetTransfer);
    _managerCheck(assetTransfer.fromAcc, msg.sender);
    _managerCheck(assetTransfer.toAcc, msg.sender);
  }

  function submitTransfers(AccountStructs.AssetTransfer[] memory assetTransfers) external {
    _submitTransfers(assetTransfers);
  }

  function _submitTransfers(AccountStructs.AssetTransfer[] memory assetTransfers) internal {
    // Do the transfers
    uint transfersLen = assetTransfers.length;

    // Keep track of seen accounts to assess risk later
    uint[] memory seenAccounts = new uint[](transfersLen * 2);
    uint nextSeenId = 0;

    for (uint i; i < transfersLen; ++i) {
      _transferAsset(assetTransfers[i]);

      uint fromAcc = assetTransfers[i].fromAcc;
      if (!_findInArray(seenAccounts, fromAcc)) {
        seenAccounts[nextSeenId++] = fromAcc;
      }
      uint toAcc = assetTransfers[i].toAcc;
      if (!_findInArray(seenAccounts, toAcc)) {
        seenAccounts[nextSeenId++] = toAcc;
      }
    }

    // Assess the risk for all modified balances
    for (uint i; i < nextSeenId; i++) {
      _managerCheck(seenAccounts[i], msg.sender);
    }
  }

  function _transferAsset(AccountStructs.AssetTransfer memory assetTransfer) internal {
    AccountStructs.AssetAdjustment memory fromAccAdjustment = AccountStructs.AssetAdjustment({
      acc: assetTransfer.fromAcc,
      asset: assetTransfer.asset,
      subId: assetTransfer.subId,
      amount: -assetTransfer.amount
    });
    AccountStructs.BalanceAndOrder storage fromBalanceAndOrder = 
      balanceAndOrder[_getEntryKey(assetTransfer.fromAcc, assetTransfer.asset, assetTransfer.subId)];

    AccountStructs.AssetAdjustment memory toAccAdjustment = AccountStructs.AssetAdjustment({
      acc: assetTransfer.toAcc,
      asset: assetTransfer.asset,
      subId: assetTransfer.subId,
      amount: assetTransfer.amount
    });
    AccountStructs.BalanceAndOrder storage toBalanceAndOrder = 
      balanceAndOrder[_getEntryKey(assetTransfer.fromAcc, assetTransfer.asset, assetTransfer.subId)];

    _allowanceCheck(fromAccAdjustment, msg.sender);
    _allowanceCheck(toAccAdjustment, msg.sender);

    _adjustBalance(fromAccAdjustment, fromBalanceAndOrder);
    _adjustBalance(toAccAdjustment, toBalanceAndOrder);
  }

  function transferAll(uint fromAccountId, uint toAccountId) external {
    _transferAll(fromAccountId, toAccountId);
    _managerCheck(fromAccountId, msg.sender);
    _managerCheck(toAccountId, msg.sender);
  }

  function _transferAll(uint fromAccountId, uint toAccountId) internal {
    require(_isApprovedOrOwner(msg.sender, fromAccountId) && _isApprovedOrOwner(msg.sender, toAccountId), 
      "msg.sender must be full delegate or owner of both accounts");

    AccountStructs.HeldAsset[] memory fromAssets = heldAssets[fromAccountId];
    uint heldAssetLen = fromAssets.length;
    for (uint i; i < heldAssetLen; i++) {
      AccountStructs.BalanceAndOrder storage userBalanceAndOrder = 
        balanceAndOrder[_getEntryKey(fromAccountId, fromAssets[i].asset, uint(fromAssets[i].subId))];

      _adjustBalance(AccountStructs.AssetAdjustment({
          acc: toAccountId,
          asset: fromAssets[i].asset,
          subId: fromAssets[i].subId,
          amount: int(userBalanceAndOrder.balance)
        }), 
        userBalanceAndOrder
      );

      _adjustBalanceWithoutHeldAssetUpdate(AccountStructs.AssetAdjustment({
          acc: fromAccountId,
          asset: fromAssets[i].asset,
          subId: fromAssets[i].subId,
          amount: -int(userBalanceAndOrder.balance)
        }), 
        userBalanceAndOrder
      );
    }

    // gas efficient to batch clear assets
    _clearAllHeldAssets(fromAccountId);
  }

  /// @dev privileged function that only the asset can call to do things like minting and burning
  function adjustBalance(
    AccountStructs.AssetAdjustment memory adjustment
  ) onlyManagerOrAsset(adjustment.acc, adjustment.asset) external returns (int postAdjustmentBalance) {
    require(msg.sender == address(manager[adjustment.acc]) || msg.sender == address(adjustment.asset),
      "only managers and assets can make assymmetric adjustments");
    
    AccountStructs.BalanceAndOrder storage userBalanceAndOrder = 
        balanceAndOrder[_getEntryKey(adjustment.acc, adjustment.asset, adjustment.subId)];

    _adjustBalance(adjustment, userBalanceAndOrder);
    _managerCheck(adjustment.acc, msg.sender); // since caller is passed, manager can internally decide to ignore check

    postAdjustmentBalance = int(userBalanceAndOrder.balance);
  }

  function _adjustBalance(
    AccountStructs.AssetAdjustment memory adjustment, 
    AccountStructs.BalanceAndOrder storage userBalanceAndOrder
) internal {
    int preBalance = int(userBalanceAndOrder.balance);
    int postBalance = int(userBalanceAndOrder.balance) + adjustment.amount;

    // removeHeldAsset does not change order, instead
    // returns newOrder and stores balance and order in one word
    uint16 newOrder = userBalanceAndOrder.order;
    if (preBalance != 0 && postBalance == 0) {
      newOrder = _removeHeldAsset(adjustment.acc, userBalanceAndOrder);
    } else if (preBalance == 0 && postBalance != 0) {
      newOrder = _addHeldAsset(adjustment.acc, adjustment.asset, adjustment.subId);
    } 

    userBalanceAndOrder.balance = postBalance.toInt240();
    userBalanceAndOrder.order = newOrder;

    _assetCheck(adjustment.asset, adjustment.subId, adjustment.acc, preBalance, postBalance, msg.sender);
  }

  function _adjustBalanceWithoutHeldAssetUpdate(
    AccountStructs.AssetAdjustment memory adjustment,
    AccountStructs.BalanceAndOrder storage userBalanceAndOrder
  ) internal{
    int preBalance = int(userBalanceAndOrder.balance);
    int postBalance = int(userBalanceAndOrder.balance) + adjustment.amount;

    userBalanceAndOrder.balance = postBalance.toInt240();

    _assetCheck(adjustment.asset, adjustment.subId, adjustment.acc, preBalance, postBalance, msg.sender);
  }

  ////////////////////////////
  // Checks and Permissions //
  ////////////////////////////

  function _managerCheck(
    uint accountId, 
    address caller
  ) internal {
    manager[accountId].handleAdjustment(accountId, _getAccountBalances(accountId), caller);
  }

  function _assetCheck(
    IAbstractAsset asset, 
    uint subId, 
    uint accountId,
    int preBalance, 
    int postBalance, 
    address caller
  ) internal {
    asset.handleAdjustment(
      accountId, preBalance, postBalance, subId, manager[accountId], caller
    );
  }

  function _allowanceCheck(
    AccountStructs.AssetAdjustment memory adjustment, address delegate
  ) internal {
    // ERC721 approved or owner get blanket allowance
    if (_isApprovedOrOwner(msg.sender, adjustment.acc)) { return; }

    bytes32 subIdKey = _getEntryKey(adjustment.acc, adjustment.asset, adjustment.subId);
    bytes32 assetKey = _getEntryKey(adjustment.acc, adjustment.asset, 0);

    // determine if positive vs negative allowance is needed
    if (adjustment.amount > 0) {
      _absAllowanceCheck(
        positiveSubIdAllowance[subIdKey],
        positiveAssetAllowance[assetKey],
        delegate,
        adjustment.amount
      );
    } else {
      _absAllowanceCheck(
        negativeSubIdAllowance[subIdKey],
        negativeAssetAllowance[assetKey],
        delegate,
        adjustment.amount
      );
    }

  }

  function _absAllowanceCheck(
    mapping(address => uint) storage allowancesForSubId,
    mapping(address => uint) storage allowancesForAsset,
    address delegate,
    int amount
  ) internal {
     // check allowance
    uint subIdAllowance = allowancesForSubId[delegate];
    uint assetAllowance = allowancesForAsset[delegate];

    // subId allowances are decremented first
    uint absAmount = _abs(amount); 
    if (absAmount <= subIdAllowance) {
      allowancesForSubId[delegate] -= absAmount;
    } else if (absAmount <= subIdAllowance + assetAllowance) { 
      allowancesForSubId[delegate] = 0;
      allowancesForAsset[delegate] -= absAmount - subIdAllowance;
    } else {
      revert("delegate does not have enough allowance");
    }
  }


  //////////
  // Util //
  //////////

  /// @dev keep mappings succinct and gas efficient
  function _getEntryKey(
    uint accountId, IAbstractAsset asset, uint subId
  ) internal pure returns (bytes32 balanceKey) {
    return keccak256(abi.encodePacked(accountId, address(asset), subId));
  } 

  /// @dev this should never be called if the account already holds the asset
  function _addHeldAsset(
    uint accountId, IAbstractAsset asset, uint subId
  ) internal returns (uint16 newOrder) {
    heldAssets[accountId].push(AccountStructs.HeldAsset({asset: asset, subId: subId.toUint96()}));
    newOrder = (heldAssets[accountId].length - 1).toUint16();
  }
  
  /// @dev this should never be called if account doesn't hold asset
  ///      using heldOrder mapping to remove
  ///      ~200000 gas overhead for 100 position portfolio

  function _removeHeldAsset(
    uint accountId, 
    AccountStructs.BalanceAndOrder memory userBalanceAndOrder
  ) internal returns (uint16 newOrder) {

    uint16 currentAssetOrder = userBalanceAndOrder.order; // 100 gas

    // swap orders if middle asset removed
    uint heldAssetLen = heldAssets[accountId].length;

    if (currentAssetOrder != heldAssetLen.toUint16() - 1) { 
      AccountStructs.HeldAsset memory assetToMove = heldAssets[accountId][heldAssetLen - 1]; // 2k gas
      // TODO: can you index with uint16?
      heldAssets[accountId][currentAssetOrder] = assetToMove; // 5k gas

      AccountStructs.BalanceAndOrder storage toMoveBalanceAndOrder = 
        balanceAndOrder[_getEntryKey(accountId, assetToMove.asset, uint(assetToMove.subId))];
      toMoveBalanceAndOrder.order = currentAssetOrder; // 5k gas 
    }

    // remove asset from heldAsset
    heldAssets[accountId].pop(); // 200 gas
    return 0;
  }

  /// @dev used for gas efficient transferAll
  function _clearAllHeldAssets(uint accountId) internal {
    AccountStructs.HeldAsset[] memory assets = heldAssets[accountId];
    uint heldAssetLen = assets.length;
    for (uint i; i < heldAssetLen; i++) {
      AccountStructs.BalanceAndOrder storage orderToClear = 
        balanceAndOrder[_getEntryKey(accountId, assets[i].asset, uint(assets[i].subId))];

      orderToClear.order = 0;
    }
    delete heldAssets[accountId];
  }

  function _abs(int amount) internal pure returns (uint absAmount) {
    return (amount >= 0) ? uint(amount) : SafeCast.toUint256(-amount);
  }

  function _findInArray(uint[] memory array, uint toFind) internal pure returns (bool found) {
    uint arrayLen = array.length;
    for (uint i; i < arrayLen; ++i) {
      if (array[i] == 0) {
        return false;
      }
      if (array[i] == toFind) {
        return true;
      }
    }
    return false;
  }

  function _findInArray(IAbstractAsset[] memory array, IAbstractAsset toFind) internal pure returns (bool found) {
    uint arrayLen = array.length;
    for (uint i; i < arrayLen; ++i) {
      if (array[i] == IAbstractAsset(address(0))) {
        return false;
      }
      if (array[i] == toFind) {
        return true;
      }
    }
    return false;
  }

  //////////
  // View //
  //////////

  function getAssetBalance(
    uint accountId, 
    IAbstractAsset asset, 
    uint subId
  ) external view returns (int balance){
    AccountStructs.BalanceAndOrder memory userBalanceAndOrder = 
            balanceAndOrder[_getEntryKey(accountId, asset, subId)];
    return int(userBalanceAndOrder.balance);
  }

  function getAccountBalances(uint accountId) external view returns (AccountStructs.AssetBalance[] memory assetBalances) {
    return _getAccountBalances(accountId);
  }

  function _getAccountBalances(uint accountId)
    internal
    view
    returns (AccountStructs.AssetBalance[] memory assetBalances)
  {
    uint allAssetBalancesLen = heldAssets[accountId].length;
    assetBalances = new AccountStructs.AssetBalance[](allAssetBalancesLen);
    for (uint i; i < allAssetBalancesLen; i++) {
      AccountStructs.HeldAsset memory heldAsset = heldAssets[accountId][i];
      AccountStructs.BalanceAndOrder memory userBalanceAndOrder = 
            balanceAndOrder[_getEntryKey(accountId, heldAsset.asset, uint(heldAsset.subId))];

      assetBalances[i] = AccountStructs.AssetBalance({
        asset: heldAsset.asset,
        subId: uint(heldAsset.subId),
        balance: int(userBalanceAndOrder.balance)
      });
    }
    return assetBalances;
  }

  ///////////////
  // Modifiers //
  ///////////////

  modifier onlyManagerOrAsset(uint accountId, IAbstractAsset asset) {
    require(msg.sender == ownerOf(accountId) || 
      msg.sender == address(asset), 
    "only manager or asset");
    _;
  }


}