// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IWNative} from "../interfaces/IWNative.sol";
import {IERC4626} from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {MarketParams, IMorpho} from "../../lib/morpho-blue/src/interfaces/IMorpho.sol";
import {CoreAdapter, ErrorsLib, IERC20, SafeERC20, Address} from "./CoreAdapter.sol";
import {MathRayLib} from "../libraries/MathRayLib.sol";
import {SafeCast160} from "../../lib/permit2/src/libraries/SafeCast160.sol";
import {Permit2Lib} from "../../lib/permit2/src/libraries/Permit2Lib.sol";
import {MorphoBalancesLib} from "../../lib/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {MarketParamsLib} from "../../lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "../../lib/morpho-blue/src/libraries/periphery/MorphoLib.sol";

/// @custom:security-contact security@morpho.org
/// @notice Chain agnostic adapter contract n°1.
contract GeneralAdapter1 is CoreAdapter {
    using SafeCast160 for uint256;
    using MarketParamsLib for MarketParams;
    using MathRayLib for uint256;

    /* IMMUTABLES */

    /// @notice The address of the Morpho contract.
    IMorpho public immutable MORPHO;

    /// @dev The address of the wrapped native token.
    IWNative public immutable WRAPPED_NATIVE;

    /* CONSTRUCTOR */

    /// @param bundler3 The address of the Bundler3 contract.
    /// @param morpho The address of the Morpho protocol.
    /// @param wNative The address of the canonical native token wrapper.
    constructor(address bundler3, address morpho, address wNative) CoreAdapter(bundler3) {
        require(morpho != address(0), ErrorsLib.ZeroAddress());
        require(wNative != address(0), ErrorsLib.ZeroAddress());

        MORPHO = IMorpho(morpho);
        WRAPPED_NATIVE = IWNative(wNative);
    }

    /* ERC4626 ACTIONS */

    /// @notice Mints shares of an ERC4626 vault.
    /// @dev Underlying tokens must have been previously sent to the adapter.
    /// @dev Assumes the given vault implements EIP-4626.
    /// @param vault The address of the vault.
    /// @param shares The amount of vault shares to mint.
    /// @param maxSharePriceE27 The maximum amount of assets to pay to get 1 share, scaled by 1e27.
    /// @param receiver The address to which shares will be minted.
    function erc4626Mint(address vault, uint256 shares, uint256 maxSharePriceE27, address receiver)
        external
        onlyBundler3
    {
        require(receiver != address(0), ErrorsLib.ZeroAddress());
        require(shares != 0, ErrorsLib.ZeroShares());

        IERC20 underlyingToken = IERC20(IERC4626(vault).asset());
        SafeERC20.forceApprove(underlyingToken, vault, type(uint256).max);

        uint256 assets = IERC4626(vault).mint(shares, receiver);

        SafeERC20.forceApprove(underlyingToken, vault, 0);

        require(assets.rDivUp(shares) <= maxSharePriceE27, ErrorsLib.SlippageExceeded());
    }

    /// @notice Deposits underlying token in an ERC4626 vault.
    /// @dev Underlying tokens must have been previously sent to the adapter.
    /// @dev Assumes the given vault implements EIP-4626.
    /// @param vault The address of the vault.
    /// @param assets The amount of underlying token to deposit. Pass `type(uint).max` to deposit the adapter's balance.
    /// @param maxSharePriceE27 The maximum amount of assets to pay to get 1 share, scaled by 1e27.
    /// @param receiver The address to which shares will be minted.
    function erc4626Deposit(address vault, uint256 assets, uint256 maxSharePriceE27, address receiver)
        external
        onlyBundler3
    {
        require(receiver != address(0), ErrorsLib.ZeroAddress());

        IERC20 underlyingToken = IERC20(IERC4626(vault).asset());
        if (assets == type(uint256).max) assets = underlyingToken.balanceOf(address(this));

        require(assets != 0, ErrorsLib.ZeroAmount());

        SafeERC20.forceApprove(underlyingToken, vault, type(uint256).max);

        uint256 shares = IERC4626(vault).deposit(assets, receiver);

        SafeERC20.forceApprove(underlyingToken, vault, 0);

        require(assets.rDivUp(shares) <= maxSharePriceE27, ErrorsLib.SlippageExceeded());
    }

    /// @notice Withdraws underlying token from an ERC4626 vault.
    /// @dev Assumes the given `vault` implements EIP-4626.
    /// @dev If `owner` is the initiator, they must have previously approved the adapter to spend their vault shares.
    /// Otherwise, vault shares must have been previously sent to the adapter.
    /// @param vault The address of the vault.
    /// @param assets The amount of underlying token to withdraw.
    /// @param minSharePriceE27 The minimum number of assets to receive per share, scaled by 1e27.
    /// @param receiver The address that will receive the withdrawn assets.
    /// @param owner The address on behalf of which the assets are withdrawn. Can only be the adapter or the initiator.
    function erc4626Withdraw(address vault, uint256 assets, uint256 minSharePriceE27, address receiver, address owner)
        external
        onlyBundler3
    {
        require(receiver != address(0), ErrorsLib.ZeroAddress());
        require(owner == address(this) || owner == initiator(), ErrorsLib.UnexpectedOwner());
        require(assets != 0, ErrorsLib.ZeroAmount());

        uint256 shares = IERC4626(vault).withdraw(assets, receiver, owner);
        require(assets.rDivDown(shares) >= minSharePriceE27, ErrorsLib.SlippageExceeded());
    }

    /// @notice Redeems shares of an ERC4626 vault.
    /// @dev Assumes the given `vault` implements EIP-4626.
    /// @dev If `owner` is the initiator, they must have previously approved the adapter to spend their vault shares.
    /// Otherwise, vault shares must have been previously sent to the adapter.
    /// @param vault The address of the vault.
    /// @param shares The amount of vault shares to redeem. Pass `type(uint).max` to redeem the owner's shares.
    /// @param minSharePriceE27 The minimum number of assets to receive per share, scaled by 1e27.
    /// @param receiver The address that will receive the withdrawn assets.
    /// @param owner The address on behalf of which the shares are redeemed. Can only be the adapter or the initiator.
    function erc4626Redeem(address vault, uint256 shares, uint256 minSharePriceE27, address receiver, address owner)
        external
        onlyBundler3
    {
        require(receiver != address(0), ErrorsLib.ZeroAddress());
        require(owner == address(this) || owner == initiator(), ErrorsLib.UnexpectedOwner());

        if (shares == type(uint256).max) shares = IERC4626(vault).balanceOf(owner);

        require(shares != 0, ErrorsLib.ZeroShares());

        uint256 assets = IERC4626(vault).redeem(shares, receiver, owner);
        require(assets.rDivDown(shares) >= minSharePriceE27, ErrorsLib.SlippageExceeded());
    }

    /* MORPHO CALLBACKS */

    /// @notice Receives supply callback from the Morpho contract.
    /// @param data Bytes containing an abi-encoded Call[].
    function onMorphoSupply(uint256, bytes calldata data) external {
        morphoCallback(data);
    }

    /// @notice Receives supply collateral callback from the Morpho contract.
    /// @param data Bytes containing an abi-encoded Call[].
    function onMorphoSupplyCollateral(uint256, bytes calldata data) external {
        morphoCallback(data);
    }

    /// @notice Receives repay callback from the Morpho contract.
    /// @param data Bytes containing an abi-encoded Call[].
    function onMorphoRepay(uint256, bytes calldata data) external {
        morphoCallback(data);
    }

    /// @notice Receives flashloan callback from the Morpho contract.
    /// @param data Bytes containing an abi-encoded Call[].
    function onMorphoFlashLoan(uint256, bytes calldata data) external {
        morphoCallback(data);
    }

    /* MORPHO ACTIONS */

    /// @notice Supplies loan asset on Morpho.
    /// @dev Either `assets` or `shares` should be zero. Most usecases should rely on `assets` as an input so the
    /// adapter is guaranteed to have `assets` tokens pulled from its balance, but the possibility to mint a specific
    /// amount of shares is given for full compatibility and precision.
    /// @dev Loan tokens must have been previously sent to the adapter.
    /// @param marketParams The Morpho market to supply assets to.
    /// @param assets The amount of assets to supply. Pass `type(uint).max` to supply the adapter's loan asset balance.
    /// @param shares The amount of shares to mint.
    /// @param maxSharePriceE27 The maximum amount of assets supplied per minted share, scaled by 1e27.
    /// @param onBehalf The address that will own the increased supply position.
    /// @param data Arbitrary data to pass to the `onMorphoSupply` callback. Pass empty data if not needed.
    function morphoSupply(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        uint256 maxSharePriceE27,
        address onBehalf,
        bytes calldata data
    ) external onlyBundler3 {
        // Do not check `onBehalf` against the zero address as it's done in Morpho.
        require(onBehalf != address(this), ErrorsLib.AdapterAddress());

        if (assets == type(uint256).max) {
            assets = IERC20(marketParams.loanToken).balanceOf(address(this));
            require(assets != 0, ErrorsLib.ZeroAmount());
        }

        // Morpho's allowance is not reset as it is trusted.
        SafeERC20.forceApprove(IERC20(marketParams.loanToken), address(MORPHO), type(uint256).max);

        (uint256 suppliedAssets, uint256 suppliedShares) = MORPHO.supply(marketParams, assets, shares, onBehalf, data);

        require(suppliedAssets.rDivUp(suppliedShares) <= maxSharePriceE27, ErrorsLib.SlippageExceeded());
    }

    /// @notice Supplies collateral on Morpho.
    /// @dev Collateral tokens must have been previously sent to the adapter.
    /// @param marketParams The Morpho market to supply collateral to.
    /// @param assets The amount of collateral to supply. Pass `type(uint).max` to supply the adapter's collateral
    /// balance.
    /// @param onBehalf The address that will own the increased collateral position.
    /// @param data Arbitrary data to pass to the `onMorphoSupplyCollateral` callback. Pass empty data if not needed.
    function morphoSupplyCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external onlyBundler3 {
        // Do not check `onBehalf` against the zero address as it's done at Morpho's level.
        require(onBehalf != address(this), ErrorsLib.AdapterAddress());

        if (assets == type(uint256).max) assets = IERC20(marketParams.collateralToken).balanceOf(address(this));

        require(assets != 0, ErrorsLib.ZeroAmount());

        // Morpho's allowance is not reset as it is trusted.
        SafeERC20.forceApprove(IERC20(marketParams.collateralToken), address(MORPHO), type(uint256).max);

        MORPHO.supplyCollateral(marketParams, assets, onBehalf, data);
    }

    /// @notice Borrows assets on Morpho.
    /// @dev Either `assets` or `shares` should be zero. Most usecases should rely on `assets` as an input so the
    /// initiator is guaranteed to borrow `assets` tokens, but the possibility to mint a specific amount of shares is
    /// given for full compatibility and precision.
    /// @dev Initiator must have previously authorized the adapter to act on their behalf on Morpho.
    /// @param marketParams The Morpho market to borrow assets from.
    /// @param assets The amount of assets to borrow.
    /// @param shares The amount of shares to mint.
    /// @param minSharePriceE27 The minimum amount of assets borrowed per borrow share minted, scaled by 1e27.
    /// @param receiver The address that will receive the borrowed assets.
    function morphoBorrow(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        uint256 minSharePriceE27,
        address onBehalf,
        address receiver
    ) external onlyBundler3 {
        address initiator = initiator();
        if(onBehalf != address(0)) initiator = onBehalf;

        (uint256 borrowedAssets, uint256 borrowedShares) =
            MORPHO.borrow(marketParams, assets, shares, initiator, receiver);

        require(borrowedAssets.rDivDown(borrowedShares) >= minSharePriceE27, ErrorsLib.SlippageExceeded());
    }

    /// @notice Repays assets on Morpho.
    /// @dev Either `assets` or `shares` should be zero. Most usecases should rely on `assets` as an input so the
    /// adapter is guaranteed to have `assets` tokens pulled from its balance, but the possibility to burn a specific
    /// amount of shares is given for full compatibility and precision.
    /// @dev Loan tokens must have been previously sent to the adapter.
    /// @param marketParams The Morpho market to repay assets to.
    /// @param assets The amount of assets to repay. Pass `type(uint).max` to repay the adapter's loan asset balance.
    /// @param shares The amount of shares to burn. Pass `type(uint).max` to repay the initiator's entire debt.
    /// @param maxSharePriceE27 The maximum amount of assets repaid per borrow share burned, scaled by 1e27.
    /// @param onBehalf The address of the owner of the debt position.
    /// @param data Arbitrary data to pass to the `onMorphoRepay` callback. Pass empty data if not needed.
    function morphoRepay(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        uint256 maxSharePriceE27,
        address onBehalf,
        bytes calldata data
    ) external onlyBundler3 {
        // Do not check `onBehalf` against the zero address as it's done at Morpho's level.
        require(onBehalf != address(this), ErrorsLib.AdapterAddress());

        if (assets == type(uint256).max) {
            assets = IERC20(marketParams.loanToken).balanceOf(address(this));
            require(assets != 0, ErrorsLib.ZeroAmount());
        }

        if (shares == type(uint256).max) {
            shares = MorphoLib.borrowShares(MORPHO, marketParams.id(), onBehalf);
            require(shares != 0, ErrorsLib.ZeroAmount());
        }

        // Morpho's allowance is not reset as it is trusted.
        SafeERC20.forceApprove(IERC20(marketParams.loanToken), address(MORPHO), type(uint256).max);

        (uint256 repaidAssets, uint256 repaidShares) = MORPHO.repay(marketParams, assets, shares, onBehalf, data);

        require(repaidAssets.rDivUp(repaidShares) <= maxSharePriceE27, ErrorsLib.SlippageExceeded());
    }

    /// @notice Withdraws assets on Morpho.
    /// @dev Either `assets` or `shares` should be zero. Most usecases should rely on `assets` as an input so the
    /// initiator is guaranteed to withdraw `assets` tokens, but the possibility to burn a specific amount of shares is
    /// given for full compatibility and precision.
    /// @dev Initiator must have previously authorized the maodule to act on their behalf on Morpho.
    /// @param marketParams The Morpho market to withdraw assets from.
    /// @param assets The amount of assets to withdraw.
    /// @param shares The amount of shares to burn. Pass `type(uint).max` to burn all the initiator's supply shares.
    /// @param minSharePriceE27 The minimum amount of assets withdraw per burn share, scaled by 1e27.
    /// @param receiver The address that will receive the withdrawn assets.
    function morphoWithdraw(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        uint256 minSharePriceE27,
        address onBehalf,
        address receiver
    ) external onlyBundler3 {
        if (shares == type(uint256).max) {
            shares = MorphoLib.supplyShares(MORPHO, marketParams.id(), initiator());
            require(shares != 0, ErrorsLib.ZeroAmount());
        }

        address initiator = initiator();
        if(onBehalf != address(0)) initiator = onBehalf;
        (uint256 withdrawnAssets, uint256 withdrawnShares) =
            MORPHO.withdraw(marketParams, assets, shares, initiator, receiver);

        require(withdrawnAssets.rDivDown(withdrawnShares) >= minSharePriceE27, ErrorsLib.SlippageExceeded());
    }

    /// @notice Withdraws collateral from Morpho.
    /// @dev Initiator must have previously authorized the adapter to act on their behalf on Morpho.
    /// @param marketParams The Morpho market to withdraw collateral from.
    /// @param assets The amount of collateral to withdraw. Pass `type(uint).max` to withdraw the initiator's collateral
    /// balance.
    /// @param receiver The address that will receive the collateral assets.
    function morphoWithdrawCollateral(MarketParams calldata marketParams, uint256 assets, address onBehalf, address receiver)
        external
        onlyBundler3
    {   
        address initiator = initiator();
        if(onBehalf != address(0)) initiator = onBehalf;
        require(assets != 0, ErrorsLib.ZeroAmount());

        MORPHO.withdrawCollateral(marketParams, assets, initiator, receiver);
    }

    /// @notice Triggers a flash loan on Morpho.
    /// @param token The address of the token to flash loan.
    /// @param assets The amount of assets to flash loan.
    /// @param data Arbitrary data to pass to the `onMorphoFlashLoan` callback.
    function morphoFlashLoan(address token, uint256 assets, bytes calldata data) external onlyBundler3 {
        require(assets != 0, ErrorsLib.ZeroAmount());
        // Morpho's allowance is not reset as it is trusted.
        SafeERC20.forceApprove(IERC20(token), address(MORPHO), type(uint256).max);

        MORPHO.flashLoan(token, assets, data);
    }

    /* PERMIT2 ACTIONS */

    /// @notice Transfers with Permit2.
    /// @param token The address of the ERC20 token to transfer.
    /// @param receiver The address that will receive the tokens.
    /// @param amount The amount of token to transfer. Pass `type(uint).max` to transfer the initiator's balance.
    function permit2TransferFrom(address token, address receiver, uint256 amount) external onlyBundler3 {
        require(receiver != address(0), ErrorsLib.ZeroAddress());

        address initiator = initiator();
        if (amount == type(uint256).max) amount = IERC20(token).balanceOf(initiator);

        require(amount != 0, ErrorsLib.ZeroAmount());

        Permit2Lib.PERMIT2.transferFrom(initiator, receiver, amount.toUint160(), token);
    }

    /* TRANSFER ACTIONS */

    /// @notice Transfers ERC20 tokens from the initiator.
    /// @notice Initiator must have given sufficient allowance to the Adapter to spend their tokens.
    /// @param token The address of the ERC20 token to transfer.
    /// @param from The address that will send the tokens overriding the initiator if needed.
    /// @param receiver The address that will receive the tokens.
    /// @param amount The amount of token to transfer. Pass `type(uint).max` to transfer the initiator's balance.
    function erc20TransferFrom(address token, address from, address receiver, uint256 amount) external onlyBundler3 {
        require(receiver != address(0), ErrorsLib.ZeroAddress());

        address initiator = initiator();
        if(from != address(0)) initiator = from;
        if (amount == type(uint256).max) amount = IERC20(token).balanceOf(initiator);

        require(amount != 0, ErrorsLib.ZeroAmount());

        SafeERC20.safeTransferFrom(IERC20(token), initiator, receiver, amount);
    }

    /* WRAPPED NATIVE TOKEN ACTIONS */

    /// @notice Wraps native tokens to wNative.
    /// @dev Native tokens must have been previously sent to the adapter.
    /// @param amount The amount of native token to wrap. Pass `type(uint).max` to wrap the adapter's balance.
    /// @param receiver The account receiving the wrapped native tokens.
    function wrapNative(uint256 amount, address receiver) external onlyBundler3 {
        if (amount == type(uint256).max) amount = address(this).balance;

        require(amount != 0, ErrorsLib.ZeroAmount());

        WRAPPED_NATIVE.deposit{value: amount}();
        if (receiver != address(this)) SafeERC20.safeTransfer(IERC20(address(WRAPPED_NATIVE)), receiver, amount);
    }

    /// @notice Unwraps wNative tokens to the native token.
    /// @dev Wrapped native tokens must have been previously sent to the adapter.
    /// @param amount The amount of wrapped native token to unwrap. Pass `type(uint).max` to unwrap the adapter's
    /// balance.
    /// @param receiver The account receiving the native tokens.
    function unwrapNative(uint256 amount, address receiver) external onlyBundler3 {
        if (amount == type(uint256).max) amount = WRAPPED_NATIVE.balanceOf(address(this));

        require(amount != 0, ErrorsLib.ZeroAmount());

        WRAPPED_NATIVE.withdraw(amount);
        if (receiver != address(this)) Address.sendValue(payable(receiver), amount);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Triggers `_multicall` logic during a callback.
    function morphoCallback(bytes calldata data) internal {
        require(msg.sender == address(MORPHO), ErrorsLib.UnauthorizedSender());
        // No need to approve Morpho to pull tokens because it should already be approved max.

        reenterBundler3(data);
    }
}
