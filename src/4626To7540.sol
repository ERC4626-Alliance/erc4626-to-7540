// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {IERC7575, IERC165} from "src/interfaces/IERC7575.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC7540Operator, IERC7540Deposit, IERC7540Redeem} from "src/interfaces/IERC7540.sol";

/**
 * @notice Wrapper for managing deposits and redemptions into an ERC-4626 vault, using the ERC-7540 interface.
 *
 *         When requestDeposit/Redeem is called, the shares/assets received from the underlying vault are
 *         held by the wrapper contract. These are transferred to the user when deposit/mint/redeem/withdraw
 *         is called.
 *
 *  @dev   THIS WRAPPER IS AN UNOPTIMIZED, POTENTIALLY UNSECURE REFERENCE EXAMPLE
 *         AND IN NO WAY MEANT TO BE USED IN PRODUCTION
 */
contract ERC4626To7540 is ERC4626, IERC7540Operator, IERC7540Deposit {
    using FixedPointMathLib for uint256;

    struct ClaimableDeposit {
        uint256 assets;
        uint256 shares;
    }

    /// @dev Assume requests are non-fungible and all have ID = 0
    uint256 internal constant REQUEST_ID = 0;

    IERC7575 public immutable vault;
    ERC20 public immutable share;

    mapping(address => ClaimableDeposit) internal _claimableDeposit;

    mapping(address => mapping(address => bool)) public isOperator;

    constructor(IERC7575 vault_)
        ERC4626(ERC20(vault_.asset()), ERC20(vault_.share()).name(), ERC20(vault_.share()).symbol())
    {
        vault = vault_;
        asset = ERC20(vault_.asset());
        share = ERC20(vault_.share()); // TODO: support non-ERC7575
    }

    /*//////////////////////////////////////////////////////////////
                       ERC7540 DEPOSIT LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view virtual override returns (uint256) {
        return vault.totalAssets();
    }

    function requestDeposit(uint256 assets, address controller, address owner)
        external
        virtual
        returns (uint256 requestId)
    {
        require(owner == msg.sender || isOperator[owner][msg.sender], "invalid-owner");
        require(asset.balanceOf(owner) >= assets, "insufficient-balance");
        require(assets != 0, "zero-assets");

        SafeTransferLib.safeTransferFrom(asset, owner, address(this), assets);
        asset.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, address(this));

        _claimableDeposit[controller].assets += assets;
        _claimableDeposit[controller].shares += shares;

        emit DepositRequest(controller, owner, REQUEST_ID, msg.sender, assets);
        return REQUEST_ID;
    }

    function pendingDepositRequest(uint256, address) public view virtual returns (uint256 pendingAssets) {
        pendingAssets = 0;
    }

    function claimableDepositRequest(uint256, address controller) public view virtual returns (uint256) {
        return maxDeposit(controller);
    }

    function maxDeposit(address controller) public view override returns (uint256) {
        return _claimableDeposit[controller].assets;
    }

    function maxMint(address controller) public view override returns (uint256) {
        return _claimableDeposit[controller].shares;
    }

    function deposit(uint256 assets, address receiver, address controller) public virtual returns (uint256 shares) {
        require(controller == msg.sender || isOperator[controller][msg.sender], "ERC7540Vault/invalid-caller");
        require(assets != 0, "Must claim nonzero amount");

        // Claiming partially introduces precision loss. The user therefore receives a rounded down amount,
        // while the claimable balance is reduced by a rounded up amount.
        ClaimableDeposit storage claimable = _claimableDeposit[controller];
        shares = assets.mulDivDown(claimable.shares, claimable.assets);
        uint256 sharesUp = assets.mulDivUp(claimable.shares, claimable.assets);

        claimable.assets -= assets;
        claimable.shares = claimable.shares > sharesUp ? claimable.shares - sharesUp : 0;

        share.transfer(receiver, shares);

        emit Deposit(receiver, controller, assets, shares);
    }

    function mint(uint256 shares, address receiver, address controller)
        public
        virtual
        override
        returns (uint256 assets)
    {
        require(controller == msg.sender || isOperator[controller][msg.sender], "invalid-caller");
        require(shares != 0, "Must claim nonzero amount");

        // Claiming partially introduces precision loss. The user therefore receives a rounded down amount,
        // while the claimable balance is reduced by a rounded up amount.
        ClaimableDeposit storage claimable = _claimableDeposit[controller];
        assets = shares.mulDivDown(claimable.assets, claimable.shares);
        uint256 assetsUp = shares.mulDivUp(claimable.assets, claimable.shares);

        claimable.assets = claimable.assets > assetsUp ? claimable.assets - assetsUp : 0;
        claimable.shares -= shares;

        share.transfer(receiver, shares);

        emit Deposit(receiver, controller, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                    ERC7540 OPERATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    function setOperator(address operator, bool approved) public virtual returns (bool success) {
        require(msg.sender != operator, "cannot-set-self-as-operator");
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        success = true;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC165 LOGIC
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool) {
        return interfaceId == type(IERC7575).interfaceId || interfaceId == type(IERC7540Deposit).interfaceId
            || interfaceId == type(IERC7540Redeem).interfaceId || interfaceId == type(IERC7540Operator).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}

/**
 * @notice Deterministic factory for ERC-4626-to-7540 wrapper contracts.
 */
contract ERC4626To7540Factory {
    event NewDeployment(address indexed wrapper, address indexed vault);

    function newWrapper(address vault) external returns (address) {
        // Salt is the destination, so every transfer proxy on every chain has the same address
        ERC4626To7540 wrapper = new ERC4626To7540{salt: keccak256(abi.encodePacked(vault))}(IERC7575(vault));
        emit NewDeployment(address(wrapper), address(vault));
        return address(wrapper);
    }

    function getAddress(address vault) external view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                keccak256(abi.encodePacked(vault)),
                keccak256(abi.encodePacked(type(ERC4626To7540).creationCode, abi.encode(vault)))
            )
        );

        return address(uint160(uint256(hash)));
    }
}
