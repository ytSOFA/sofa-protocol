// SPDX-License-Identifier: MIT

pragma solidity 0.8.10;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IPermit2.sol";
import "../interfaces/IDNTStrategy.sol";
import "../interfaces/IHlOracle.sol";
import "../interfaces/IFeeCollector.sol";
import "../libs/SignatureDecoding.sol";

contract LeverageDNTVault is Initializable, ContextUpgradeable, ERC1155Upgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20Metadata;
    using SignatureDecoding for bytes;

    struct Product {
        uint256 term;
        uint256 expiry;
        uint256[2] anchorPrices;
        uint256 collateralAtRiskPercentage;
        uint256 isMaker;
    }
    struct MintParams {
        uint256 expiry;
        uint256[2] anchorPrices;
        uint256 collateralAtRisk;
        uint256 makerCollateral;
        uint256 makerBalanceThreshold;
        uint256 deadline;
        address maker;
        bytes makerSignature;
    }

    bytes32 public DOMAIN_SEPARATOR;
    // bytes32 public constant EIP712DOMAIN_TYPEHASH = keccak256(
    //     "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    // );
    bytes32 public constant EIP712DOMAIN_TYPEHASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;
    // bytes32 public constant MINT_TYPEHASH = keccak256(
    //     "Mint(address minter,uint256 totalCollateral,uint256 expiry,uint256[2] anchorPrices,uint256 collateralAtRisk,uint256 makerCollateral,uint256 makerBalanceThreshold,uint256 deadline,address vault)"
    // );
    bytes32 public constant MINT_TYPEHASH = 0xc7f7de88d8af971dc331c90646290c0b9c3f2047f8964852abdcb4fce18c7380;
    uint256 public constant LEVERAGE_RATIO = 9; // 9x
    uint256 internal constant SECONDS_IN_YEAR = 365 days;

    string public name;
    string public symbol;

    IWETH public WETH;
    IPermit2 public PERMIT2;
    IDNTStrategy public STRATEGY;
    IERC20Metadata public COLLATERAL;
    IHlOracle public ORACLE;

    uint256 public depositAPR;
    uint256 public totalFee;
    address public feeCollector;

    // Events
    event Minted(address minter, address maker, address referral, uint256 totalCollateral, uint256 term, uint256 expiry, uint256[2] anchorPrices, uint256 makerCollateral, uint256 collateralAtRiskPercentage);
    event Burned(address operator, uint256 productId, uint256 amount, uint256 payoff);
    event BatchBurned(address operator, uint256[] productIds, uint256[] amounts, uint256[] payoffs);
    event FeeCollected(address collector, uint256 amount);
    event APRUpdated(uint256 apr);

    modifier onlyETHVault() {
        require(address(COLLATERAL) == address(WETH), "Vault: only ETH vault");
        _;
    }

    receive() external payable {}

    function initialize(
        string memory name_,
        string memory symbol_,
        IPermit2 permit_,
        IDNTStrategy strategy_,
        address weth_,
        address collateral_,
        address feeCollector_,
        uint256 depositAPR_,
        IHlOracle oracle_
    ) initializer external {
        name = name_;
        symbol = symbol_;

        WETH = IWETH(weth_);
        PERMIT2 = permit_;
        STRATEGY = strategy_;

        COLLATERAL = IERC20Metadata(collateral_);
        ORACLE = oracle_;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                EIP712DOMAIN_TYPEHASH,
                keccak256("Vault"),
                keccak256("1.0"),
                block.chainid,
                address(this)
            )
        );
        feeCollector = feeCollector_;
        depositAPR = depositAPR_;

        __Ownable_init();
    }

    function mint(
        uint256 totalCollateral,
        MintParams calldata params,
        bytes calldata minterPermitSignature,
        uint256 nonce,
        address referral
    ) external {
        // transfer collateral
        uint256 depositAmount = totalCollateral - params.makerCollateral;
        PERMIT2.permitTransferFrom(
            IPermit2.PermitTransferFrom({
                permitted: IPermit2.TokenPermissions({
                    token: COLLATERAL,
                    amount: depositAmount
                }),
                nonce: nonce,
                deadline: params.deadline
            }),
            IPermit2.SignatureTransferDetails({
                to: address(this),
                requestedAmount: depositAmount
            }),
            _msgSender(),
            minterPermitSignature
        );

        _mint(totalCollateral, params, referral);
    }

    function mint(
        MintParams calldata params,
        address referral
    ) external payable onlyETHVault {
        WETH.deposit{value: msg.value}();
        _mint(
            params.makerCollateral + msg.value,
            params,
            referral
        );
    }

    function _mint(uint256 totalCollateral, MintParams memory params, address referral) internal {
        require(block.timestamp < params.deadline, "Vault: deadline");
        require(block.timestamp < params.expiry, "Vault: expired");
        // require expiry must be 8:00 UTC
        require(params.expiry % 86400 == 28800, "Vault: invalid expiry");
        require(params.anchorPrices[0] < params.anchorPrices[1], "Vault: invalid strike prices");
        require(params.makerBalanceThreshold <= COLLATERAL.balanceOf(params.maker), "Vault: invalid balance threshold");
        require(referral != _msgSender(), "Vault: invalid referral");

        {
        // verify maker's signature
        bytes32 digest =
            keccak256(abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(MINT_TYPEHASH,
                                     _msgSender(),
                                     totalCollateral,
                                     params.expiry,
                                     keccak256(abi.encodePacked(params.anchorPrices)),
                                     params.collateralAtRisk,
                                     params.makerCollateral,
                                     params.makerBalanceThreshold,
                                     params.deadline,
                                     address(this)))
        ));
        (uint8 v, bytes32 r, bytes32 s) = params.makerSignature.decodeSignature();
        require(params.maker == ecrecover(digest, v, r, s), "Vault: invalid maker signature");

        // transfer makercollateral
        COLLATERAL.safeTransferFrom(params.maker, address(this), params.makerCollateral);
        }
        uint256 term;
        uint256 collateralAtRiskPercentage;
        // mint product
        {
        // startDate = ((expiry-28800)/86400+1)*86400+28800
        term = (params.expiry - (((block.timestamp - 28800) / 86400 + 1) * 86400 + 28800)) / 86400;
        require(term > 0, "Vault: invalid term");

        // (totalCollateral - makerCollateral) = minterCollateral + minterCollateral * LEVERAGE_RATIO * depositAPR / SECONDS_IN_YEAR * (expiry - block.timestamp)
        uint256 minterCollateral = (totalCollateral - params.makerCollateral) * 1e18 / (1e18 + LEVERAGE_RATIO * depositAPR * (params.expiry - block.timestamp) / SECONDS_IN_YEAR);
        // share = (10x + makerCollateral) * (1 + depositAPR / SECONDS_IN_YEAR * LEVERAGE_RATIO / 10) - fee
        uint256 fee = minterCollateral * LEVERAGE_RATIO * depositAPR * (params.expiry - block.timestamp) * IFeeCollector(feeCollector).feeRate() / SECONDS_IN_YEAR / 1e18 / 1e18;
        totalFee += fee;
        uint256 share = totalCollateral - fee;
        collateralAtRiskPercentage = params.collateralAtRisk * 1e18 / share;

        uint256 productId = getProductId(term, params.expiry, params.anchorPrices, collateralAtRiskPercentage, uint256(0));
        uint256 makerProductId = getProductId(term, params.expiry, params.anchorPrices, collateralAtRiskPercentage, uint256(1));
        _mint(_msgSender(), productId, share, "");
        _mint(params.maker, makerProductId, share, "");
        }

        emit Minted(_msgSender(), params.maker, referral, totalCollateral, term, params.expiry, params.anchorPrices, params.makerCollateral, collateralAtRiskPercentage);
    }

    function burn(uint256 term, uint256 expiry, uint256[2] calldata anchorPrices, uint256 collateralAtRiskPercentage, uint256 isMaker) external {
        uint256 payoff = _burn(term, expiry, anchorPrices, collateralAtRiskPercentage, isMaker);
        if (payoff > 0) {
            COLLATERAL.safeTransfer(_msgSender(), payoff);
        }
    }

    function ethBurn(uint256 term, uint256 expiry, uint256[2] calldata anchorPrices, uint256 collateralAtRiskPercentage, uint256 isMaker) external onlyETHVault {
        uint256 payoff = _burn(term, expiry, anchorPrices, collateralAtRiskPercentage, isMaker);
        if (payoff > 0) {
            WETH.withdraw(payoff);
            payable(_msgSender()).transfer(payoff);
        }
    }

    function _burn(uint256 term, uint256 expiry, uint256[2] memory anchorPrices, uint256 collateralAtRiskPercentage, uint256 isMaker) internal nonReentrant returns (uint256 payoff) {
        (uint256 latestTerm, bool _isBurnable) = isBurnable(term, expiry, anchorPrices);
        require(_isBurnable, "Vault: not burnable");

        // check if settled
        uint256 latestExpiry = (block.timestamp - 28800) / 86400 * 86400 + 28800;
        require(ORACLE.settlePrices(latestExpiry, 1) > 0, "Vault: not settled");

        uint256 productId = getProductId(term, expiry, anchorPrices, collateralAtRiskPercentage, isMaker);
        uint256 amount = balanceOf(_msgSender(), productId);
        require(amount > 0, "Vault: zero amount");

        // calculate payoff by strategy
        uint256 fee;
        if (isMaker == 1) {
            (payoff, fee) = getMakerPayoff(latestTerm, latestExpiry, anchorPrices, collateralAtRiskPercentage, amount);
        } else {
            (payoff, fee) = getMinterPayoff(latestTerm, latestExpiry, anchorPrices, collateralAtRiskPercentage, amount);
        }

        // burn product
        _burn(_msgSender(), productId, amount);

        // check self balance of collateral and transfer payoff
        if (payoff > 0) {
            totalFee += fee;
        }
        emit Burned(_msgSender(), productId, amount, payoff);
    }

    function burnBatch(Product[] calldata products) external {
        uint256 totalPayoff = _burnBatch(products);

        if (totalPayoff > 0) {
            COLLATERAL.safeTransfer(_msgSender(), totalPayoff);
        }
    }

    function ethBurnBatch(Product[] calldata products) external onlyETHVault {
       uint256 totalPayoff = _burnBatch(products);

       if (totalPayoff > 0) {
           WETH.withdraw(totalPayoff);
           payable(_msgSender()).transfer(totalPayoff);
       }
    }

    function _burnBatch(Product[] calldata products) internal nonReentrant returns (uint256 totalPayoff) {
        uint256[] memory productIds = new uint256[](products.length);
        uint256[] memory amounts = new uint256[](products.length);
        uint256[] memory payoffs = new uint256[](products.length);
        for (uint256 i = 0; i < products.length; i++) {
            // check if settled
            uint256 latestExpiry = (block.timestamp - 28800) / 86400 * 86400 + 28800;
            require(ORACLE.settlePrices(latestExpiry, 1) > 0, "Vault: not settled");

            Product memory product = products[i];
            (uint256 latestTerm, bool _isBurnable) = isBurnable(product.term, product.expiry, product.anchorPrices);
            require(_isBurnable, "Vault: not burnable");

            uint256 productId = getProductId(product.term, product.expiry, product.anchorPrices, product.collateralAtRiskPercentage, product.isMaker);
            uint256 amount = balanceOf(_msgSender(), productId);
            require(amount > 0, "Vault: zero amount");

            // calculate payoff by strategy
            uint256 fee;
            if (product.isMaker == 1) {
                (payoffs[i], fee) = getMakerPayoff(latestTerm, latestExpiry, product.anchorPrices, product.collateralAtRiskPercentage, amount);
            } else {
                (payoffs[i], fee) = getMinterPayoff(latestTerm, latestExpiry, product.anchorPrices, product.collateralAtRiskPercentage, amount);
            }
            if (payoffs[i] > 0) {
                totalFee += fee;
                totalPayoff += payoffs[i];
            }

            productIds[i] = productId;
            amounts[i] = amount;
        }
        // burn product
        _burnBatch(_msgSender(), productIds, amounts);
        emit BatchBurned(_msgSender(), productIds, amounts, payoffs);
    }

    // withdraw fee
    function harvest() external {
        require(totalFee > 0, "Vault: zero fee");
        uint256 fee = totalFee;
        totalFee = 0;
        COLLATERAL.safeTransfer(feeCollector, fee);

        emit FeeCollected(_msgSender(), fee);
    }

    // update depositAPR
    function updateDepositAPR(uint256 depositAPR_) external onlyOwner {
        depositAPR = depositAPR_;
        emit APRUpdated(depositAPR_);
    }

    function getMakerPayoff(uint256 term, uint256 expiry, uint256[2] memory anchorPrices, uint256 collateralAtRiskPercentage, uint256 amount) public view returns (uint256 payoff, uint256 fee) {
        uint256 maxPayoff = amount * collateralAtRiskPercentage / 1e18;
        uint256 payoffWithFee = STRATEGY.getMakerPayoff(anchorPrices, ORACLE.getHlPrices(term, expiry), maxPayoff);
        fee = payoffWithFee * IFeeCollector(feeCollector).feeRate() / 1e18;
        payoff = payoffWithFee - fee;
    }

    function getMinterPayoff(uint256 term, uint256 expiry, uint256[2] memory anchorPrices, uint256 collateralAtRiskPercentage, uint256 amount) public view returns (uint256 payoff, uint256 fee) {
        uint256 maxPayoff = amount * collateralAtRiskPercentage / 1e18;
        uint256 payoffWithFee = STRATEGY.getMinterPayoff(anchorPrices, ORACLE.getHlPrices(term, expiry), maxPayoff);
        fee = payoffWithFee * IFeeCollector(feeCollector).feeRate() / 1e18;
        payoff = payoffWithFee - fee + (amount - amount * collateralAtRiskPercentage / 1e18);
    }

    // get product id by term, expiry and strike prices
    function getProductId(uint256 term, uint256 expiry, uint256[2] memory anchorPrices, uint256 collateralAtRiskPercentage, uint256 isMaker) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(term, expiry, anchorPrices, collateralAtRiskPercentage, isMaker)));
    }

    // get decimals
    function decimals() external view returns (uint8) {
        return COLLATERAL.decimals();
    }

    // check if the product is burnable
    function isBurnable(uint256 term, uint256 expiry, uint256[2] memory anchorPrices)
        public
        view
        returns (uint256, bool)
    {
        if (expiry <= block.timestamp) {
            return (term, true);
        } else {
            uint256 latestExpiry = (block.timestamp - 28800) / 86400 * 86400 + 28800;
            uint256 termGap = (expiry - latestExpiry) / 86400;
            if (termGap > term) {
                return (term, false);
            } else {
                uint256 latestTerm = term - termGap;
                uint256[2] memory prices = ORACLE.getHlPrices(latestTerm, latestExpiry);
                return(latestTerm, prices[0] <= anchorPrices[0] || prices[1] >= anchorPrices[1]);
            }
        }
    }

    uint256[50] private __gap;
}
