pragma solidity >=0.5.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import "@openzeppelin/contracts/math/SafeMath.sol";
import '../interfaces/IStaking.sol';
import '../interfaces/IBTCParam.sol';
import '../interfaces/ILpStaking.sol';
import './POWERC20.sol';

contract POWToken is POWERC20 {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bool internal initialized;
    address public owner;
    address public paramSetter;
    address public minter;

    // 流动性挖矿的池子
    address public stakingPool;
    address public lpStakingPool;
    // btc参数获取
    address public btcParam;

    // 每T功率比(3位小数转换到T/w)
    uint256 public elecPowerPerTHSec;
    // 开始挖矿时间
    uint256 public startMiningTime;

    // 每度电费(6位小数转换到$/kwh)
    uint256 public electricCharge;
    // 矿池手续费用比(25000)(2.5%)
    uint256 public minerPoolFeeNumerator;
    // 折旧费率
    uint256 public depreciationNumerator;

    // 记录历史工作率
    uint256 public workingRateNumerator;
    // 最后一次更新历史工作率的时间
    uint256 public workerNumLastUpdateTime;

    // 发行算力token的总数
    uint256 public totalHashRate;
    // 在运行的算力token数
    uint256 public workingHashRate;

    // wbtc 代币
    IERC20 public incomeToken;
    // btc收入率
    uint256 public incomeRate;

    // mars 代币
    IERC20 public rewardsToken;
    // 平台代币奖励率(mars/s)每秒获取多少mars
    uint256 public rewardRate;
    // 奖励持续时间(30天)
    uint256 public rewardsDuration;
    // mars代币挖矿结束时间
    uint256 public rewardPeriodFinish;
    // 质押奖励回报率
    uint256 public stakingRewardRatio;

    function initialize(
        string memory name,
        string memory symbol,
        address newOwner,
        address _paramSetter,
        address _stakingPool,
        address _lpStakingPool,
        address _minter,
        address _btcParam,
        address _incomeToken,
        address _rewardsToken,
        uint256 _elecPowerPerTHSec,
        uint256 _startMiningTime,
        uint256 _electricCharge,
        uint256 _minerPoolFeeNumerator,
        uint256 _totalHashRate
    ) public {
        require(!initialized, "Token already initialized");
        require(newOwner != address(0), "new owner is the zero address");
        require(_paramSetter != address(0), "_paramSetter is the zero address");
        require(_startMiningTime > block.timestamp, "nonlegal startMiningTime.");
        require(_minerPoolFeeNumerator < 1000000, "nonlegal minerPoolFeeNumerator.");

        initialized = true;
        initializeToken(name, symbol);

        owner = newOwner;
        paramSetter = _paramSetter;
        stakingPool = _stakingPool;
        lpStakingPool = _lpStakingPool;
        minter = _minter;
        btcParam = _btcParam;

        incomeToken = IERC20(_incomeToken);
        rewardsToken = IERC20(_rewardsToken);

        elecPowerPerTHSec = _elecPowerPerTHSec;
        startMiningTime = _startMiningTime;
        electricCharge = _electricCharge;
        minerPoolFeeNumerator = _minerPoolFeeNumerator;
        totalHashRate = _totalHashRate;

        rewardsDuration = 30 days;
        stakingRewardRatio = 20;
        depreciationNumerator = 1000000;
        workingHashRate = _totalHashRate;
        workerNumLastUpdateTime = startMiningTime;
        updateIncomeRate();
    }

    function setStakingRewardRatio(uint256 _stakingRewardRatio) external onlyOwner {
        require(_stakingRewardRatio <= 100, "illegal _stakingRewardRatio");

        updateStakingPoolReward();
        updateLpStakingPoolReward();
        stakingRewardRatio = _stakingRewardRatio;
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

    function pause() onlyOwner external {
        _pause();
    }

    function unpause() onlyOwner external {
        _unpause();
    }

    // 获取剩余的可以购买代币
    function remainingAmount() public view returns(uint256) {
        return totalHashRate.mul(1e18).sub(totalSupply);
    }

    function mint(address to, uint value) external whenNotPaused {
        require(msg.sender == minter, "!minter");
        require(value <= remainingAmount(), "not sufficient supply.");
        _mint(to, value);
        updateLpStakingPoolIncome();
    }

    function addHashRate(uint256 hashRate) external onlyParamSetter {
        require(hashRate > 0, "hashRate cannot be 0");

        // should keep current workingRate and incomeRate unchanged.
        totalHashRate = totalHashRate.add(hashRate.mul(totalHashRate).div(workingHashRate));
        workingHashRate = workingHashRate.add(hashRate);
    }

    function setBtcParam(address _btcParam) external onlyParamSetter {
        require(btcParam != _btcParam, "same btcParam.");
        btcParam = _btcParam;
        updateIncomeRate();
    }

    function setStartMiningTime(uint256 _startMiningTime) external onlyParamSetter {
        require(startMiningTime != _startMiningTime, "same startMiningTime.");
        require(startMiningTime > block.timestamp, "already start mining.");
        require(_startMiningTime > block.timestamp, "nonlegal startMiningTime.");
        startMiningTime = _startMiningTime;
        workerNumLastUpdateTime = _startMiningTime;
    }

    function setElectricCharge(uint256 _electricCharge) external onlyParamSetter {
        require(electricCharge != _electricCharge, "same electricCharge.");
        electricCharge = _electricCharge;
        updateIncomeRate();
    }

    // 设置矿池手续费
    function setMinerPoolFeeNumerator(uint256 _minerPoolFeeNumerator) external onlyParamSetter {
        require(minerPoolFeeNumerator != _minerPoolFeeNumerator, "same minerPoolFee.");
        require(_minerPoolFeeNumerator < 1000000, "nonlegal minerPoolFee.");
        minerPoolFeeNumerator = _minerPoolFeeNumerator;
        updateIncomeRate();
    }

    function setDepreciationNumerator(uint256 _depreciationNumerator) external onlyParamSetter {
        require(depreciationNumerator != _depreciationNumerator, "same depreciationNumerator.");
        require(_depreciationNumerator <= 1000000, "nonlegal depreciation.");
        depreciationNumerator = _depreciationNumerator;
        updateIncomeRate();
    }

    // 设置工作的机器数
    function setWorkingHashRate(uint256 _workingHashRate) external onlyParamSetter {
        require(workingHashRate != _workingHashRate, "same workingHashRate.");
        //require(totalHashRate >= _workingHashRate, "param workingHashRate not legal.");

        if (block.timestamp > startMiningTime) {
            workingRateNumerator = getHistoryWorkingRate();
            workerNumLastUpdateTime = block.timestamp;
        }

        workingHashRate = _workingHashRate;
        updateIncomeRate();
    }

    // 获取历史平均工作效率
    function getHistoryWorkingRate() public view returns (uint256) {
        if (block.timestamp > startMiningTime) {
            // 时间间隔
            uint256 time_interval = block.timestamp.sub(workerNumLastUpdateTime);
            // 计算到目前为止，所有的工作率
            uint256 totalRate = workerNumLastUpdateTime.sub(startMiningTime).mul(workingRateNumerator).add(time_interval.mul(getCurWorkingRate()));
            uint256 totalTime = block.timestamp.sub(startMiningTime);

            return totalRate.div(totalTime);
        }

        return 0;
    }

    // 当前工作率（正在工作的机器占全部机器的占比）
    function getCurWorkingRate() public view  returns (uint256) {
        return 1000000 * workingHashRate / totalHashRate;
    }

    // 获取每T每秒的电费转换位BTC（18位小数）
    function getPowerConsumptionBTCInWeiPerSec() public view returns(uint256){
        uint256 btcPrice = IBTCParam(btcParam).btcPrice();
        if (btcPrice != 0) {
            uint256 Base = 1e18;
            uint256 elecPowerPerTHSecAmplifier = 1000;
            // 每T/H的功率(elecPowerPerTHsec)(小数3位转变位W) 电费需要转换位kw
            uint256 powerConsumptionPerHour = elecPowerPerTHSec.mul(Base).div(elecPowerPerTHSecAmplifier).div(1000);
            uint256 powerConsumptionBTCInWeiPerHour = powerConsumptionPerHour.mul(electricCharge).div(1000000).div(btcPrice);
            return powerConsumptionBTCInWeiPerHour.div(3600);
        }
        return 0;
    }

    // 获取每T每秒BTC奖励（18位小数）
    function getIncomeBTCInWeiPerSec() public view returns(uint256){
        uint256 paramDenominator = 1000000;
        uint256 afterMinerPoolFee = 0;
        {
            uint256 btcIncomePerTPerSecInWei = IBTCParam(btcParam).btcIncomePerTPerSecInWei();
            // 剔除矿池手续费后用户获取的收益
            afterMinerPoolFee = btcIncomePerTPerSecInWei.mul(paramDenominator.sub(minerPoolFeeNumerator)).div(paramDenominator);
        }
        // 计算折旧
        uint256 afterDepreciation = 0;
        {
            afterDepreciation = afterMinerPoolFee.mul(depreciationNumerator).div(paramDenominator);
        }

        return afterDepreciation;
    }

    // 更新BTC奖励
    function updateIncomeRate() public {
        //not start mining yet.
        // 还没有开始挖矿
        if (block.timestamp > startMiningTime) {
            // update income first.
            updateStakingPoolIncome();
            updateLpStakingPoolIncome();
        }

        uint256 oldValue = incomeRate;

        //compute electric charge.
        // 每T的电费
        uint256 powerConsumptionBTCInWeiPerSec = getPowerConsumptionBTCInWeiPerSec();

        //compute btc income
        // 每T的BTC产出
        uint256 incomeBTCInWeiPerSec = getIncomeBTCInWeiPerSec();

        if (incomeBTCInWeiPerSec > powerConsumptionBTCInWeiPerSec) {
            // 减去电费
            uint256 targetRate = incomeBTCInWeiPerSec.sub(powerConsumptionBTCInWeiPerSec);
            incomeRate = targetRate.mul(workingHashRate).div(totalHashRate);
        }
        //miner close down.
        else {
            incomeRate = 0;
        }

        emit IncomeRateChanged(oldValue, incomeRate);
    }

    function updateStakingPoolIncome() internal {
        if (stakingPool != address(0)) {
            IStaking(stakingPool).incomeRateChanged();
        }
    }

    function updateLpStakingPoolIncome() internal {
        if (lpStakingPool != address(0)) {
            ILpStaking(lpStakingPool).lpIncomeRateChanged();
        }
    }

    // 更新staking池中btc的收益数据
    function updateStakingPoolReward() internal {
        if (stakingPool != address(0)) {
            IStaking(stakingPool).rewardRateChanged();
        }
    }

    // 更新lpstaking池中的btc收益数据
    function updateLpStakingPoolReward() internal {
        if (lpStakingPool != address(0)) {
            ILpStaking(lpStakingPool).lpRewardRateChanged();
        }
    }

    // 质押mars奖励
    function stakingRewardRate() public view returns(uint256) {
        return rewardRate.mul(stakingRewardRatio).div(100);
    }

    // 流动性挖矿mars奖励
    function lpStakingRewardRate() external view returns(uint256) {
        uint256 _stakingRewardRate = stakingRewardRate();
        return rewardRate.sub(_stakingRewardRate);
    }

    // 发送mars代币到本合约地址，同时更新mars代币的发放率
    function notifyRewardAmount(uint256 reward) external onlyOwner {
        updateStakingPoolReward();
        updateLpStakingPoolReward();

        // 判断是否到了下一期的时间
        if (block.timestamp >= rewardPeriodFinish) {
            // 如果到了下一期，直接更新奖励率
            rewardRate = reward.div(rewardsDuration);
        } else {
            // 如果还没有到，需要加上上一期剩余的token
            uint256 remaining = rewardPeriodFinish.sub(block.timestamp);
            // 剩余token数量
            uint256 leftover = remaining.mul(rewardRate);
            // 计算新的mars方法速率
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        // 查看当前代币余额是否足够发放
        uint balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= balance.div(rewardsDuration), "Provided reward too high");

        // 更新本期到期时间
        rewardPeriodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    // 用户领取BTC奖励
    function claimIncome(address to, uint256 amount) external {
        require(to != address(0), "to is the zero address");
        require(msg.sender == stakingPool || msg.sender == lpStakingPool, "No permissions");
        incomeToken.safeTransfer(to, amount);
    }

    // 用户领取mars奖励
    function claimReward(address to, uint256 amount) external {
        require(to != address(0), "to is the zero address");
        require(msg.sender == stakingPool || msg.sender == lpStakingPool, "No permissions");
        rewardsToken.safeTransfer(to, amount);
    }

    // 预估会有剩余的token，可以通过这个方法取回多余的token
    function inCaseTokensGetStuck(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "!owner");
        _;
    }

    modifier onlyParamSetter() {
        require(msg.sender == paramSetter, "!paramSetter");
        _;
    }

    event IncomeRateChanged(uint256 oldValue, uint256 newValue);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ParamSetterChanged(address indexed previousSetter, address indexed newSetter);
    event RewardAdded(uint256 reward);
}