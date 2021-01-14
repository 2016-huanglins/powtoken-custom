pragma solidity >=0.5.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import "@openzeppelin/contracts/math/SafeMath.sol";
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import "../interfaces/IPOWToken.sol";
import "../interfaces/IERC20Detail.sol";
import "../utils/ReentrancyGuard.sol";

contract TokenDistributeCustom is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bool internal initialized;
    address public owner;
    address public paramSetter;

    struct hashRateToken {
        mapping(address => uint256) exchangeTokenRates;
    }

    mapping(address => hashRateToken) hashRateTokens;

    mapping(address => bool) public isWhiteListed;

    function initialize(address newOwner, address _paramSetter) public {
        require(!initialized, "Token already initialized");
        require(newOwner != address(0), "new owner is the zero address");
        super.initialize();
        initialized = true;

        owner = newOwner;
        paramSetter = _paramSetter;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "new owner is the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setParamSetter(address _paramSetter) external onlyOwner {
        require(_paramSetter != address(0), "param setter is the zero address");
        emit ParamSetterChanged(paramSetter, _paramSetter);
        paramSetter = _paramSetter;
    }

    function addWhiteLists(address[] calldata _users) external onlyParamSetter {
        for (uint i = 0; i < _users.length; i++) {
            address _user = _users[i];
            _addWhiteList(_user);
        }
    }

    function addWhiteList(address _user) external onlyParamSetter {
        _addWhiteList(_user);
    }

    function _addWhiteList(address _user) internal {
        isWhiteListed[_user] = true;
        emit AddedWhiteList(_user);
    }

    function removeWhiteList(address _user) external onlyParamSetter {
        delete isWhiteListed[_user];
        emit  RemovedWhiteList(_user);
    }

    function getWhiteListStatus(address _user) public view returns (bool) {
        return isWhiteListed[_user];
    }

    function addExchangeToken(address _hashRateToken, address _exchangeToken, uint256 _exchangeRate) external onlyParamSetter {
        hashRateTokens[_hashRateToken].exchangeTokenRates[_exchangeToken] = _exchangeRate;
    }

    function updateExchangeRate(address _hashRateToken, address _exchangeToken, uint256 _exchangeRate) external onlyParamSetter checkTokenId(_hashRateToken, _exchangeToken) {
        hashRateTokens[_hashRateToken].exchangeTokenRates[_exchangeToken] = _exchangeRate;
    }

    function remainingAmount(address _hashRateToken) public view returns (uint256) {
        return IPOWToken(_hashRateToken).remainingAmount();
    }

    function exchange(address _hashRateToken, address _exchangeToken, uint256 amount, address to) checkTokenId(_hashRateToken,_exchangeToken) external nonReentrant {
        require(amount > 0, "Cannot exchange 0");
        require(amount <= remainingAmount(_hashRateToken), "not sufficient supply");
        require(getWhiteListStatus(to), "to is not in whitelist");

        uint256 exchangeRateAmplifier = 1000;
        uint256 hashRateTokenAmplifier;
        uint256 exchangeTokenAmplifier;
        {
            uint256 hashRateTokenDecimal = IERC20Detail(_hashRateToken).decimals();
            uint256 exchangeTokenDecimal = IERC20Detail(_exchangeToken).decimals();
            hashRateTokenAmplifier = 10 ** hashRateTokenDecimal;
            exchangeTokenAmplifier = 10 ** exchangeTokenDecimal;
        }

        uint256 exchangeRate = hashRateTokens[_hashRateToken].exchangeTokenRates[_exchangeToken];

        uint256 tmp = amount.mul(exchangeRate).mul(exchangeTokenAmplifier);
        uint256 token_amount = tmp.div(hashRateTokenAmplifier).div(exchangeRateAmplifier);

        {
            IERC20(_exchangeToken).safeTransferFrom(msg.sender, address(this), token_amount);
            IPOWToken(_hashRateToken).mint(to, amount);
        }

        emit Exchanged(msg.sender, _hashRateToken, _exchangeToken, amount, token_amount);
    }

    function ownerMint(address _hashRateToken, uint256 amount) external onlyOwner {
        IPOWToken(_hashRateToken).mint(owner, amount);
    }

    function ownerWithdraw(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(owner, _amount);
    }

    modifier checkTokenId(address _hashRateToken, address _exchangeTokens) {
        uint256 exchangeRate = hashRateTokens[_hashRateToken].exchangeTokenRates[_exchangeTokens];
        require(exchangeRate != 0, "wrong exchangeRate");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "!owner");
        _;
    }

    modifier onlyParamSetter() {
        require(msg.sender == paramSetter, "!param setter");
        _;
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ParamSetterChanged(address indexed previousSetter, address indexed newSetter);
    event Exchanged(address indexed user, address hashRateToken, address exchangeToken, uint256 amount, uint256 token_amount);
    event AddedWhiteList(address _user);
    event RemovedWhiteList(address _user);
}