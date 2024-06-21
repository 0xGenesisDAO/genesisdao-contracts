// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IERC20MintableBurnable is IERC20 {
    function mint(address account, uint256 amount) external;
    function burn(uint256 amount) external;
}

contract GenesisAutoCompoundStaking is IERC20, Ownable {
    uint256 private constant MAX_UINT256 = type(uint256).max;
    uint256 private constant SCALE = 1e18;
    uint256 private constant ONE_YEAR = 365 days;

    uint256 private constant MAX_STAKE_TAX = 500; // 5%
    uint256 private constant MAX_UNSTAKE_TAX = 1500; // 15%
    uint256 private constant PERCENTAGE_BASE = 10000; // 100%

    string public name = "Genesis Staking";
    string public symbol = "sGEN";
    uint8 public decimals = 18;

    address public baseToken;
    address public liquidityPool;
    address public treasury;

    uint256 public fixedAPR = 50 ether;
    uint256 public dynamicAPRMinCap = 30 ether;
    uint256 public dynamicAPRMaxCap = 70 ether;
    uint256 public dynamicAPRConstant = 1 ether;
    uint256 public rebaseInterval = 8 hours;
    uint256 public stakeTax = 500;
    uint256 public unstakeTax = 500;

    uint256 public stakeStartTime;
    uint256 public lastRebaseTime;

    uint256 public totalGons;
    uint256 public totalSupplyTokens;
    uint256 public gonsPerFragment = 1e9;

    uint256 public initialMaxSupply;
    uint256 public maxSupply;
    uint256 public maxGons;

    uint256 public warmupPeriod;

    mapping(address => uint256) private _gonBalances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => uint256) public stakeTimes;

    event Mint(address indexed wallet, uint256 amount, uint256 gonsAdded, uint256 gonsPerFragment, uint256 newTotalSupply);
    event Burn(address indexed wallet, uint256 amount, uint256 gonsRemoved, uint256 gonsPerFragment, uint256 newTotalSupply);
    event Stake(address indexed user, uint256 amount, uint256 taxAmount, uint256 mintedTokens);
    event Unstake(address indexed user, uint256 amount, uint256 taxAmount, uint256 returnedTokens);
    event Rebase(
        uint256 fixedAPR, 
        uint256 dynamicAPR, 
        uint256 rebaseAPR, 
        uint256 lastRebaseTime, 
        uint256 rebaseCount, 
        uint256 maxSupply, 
        uint256 supplyDelta,
        uint256 gonsPerFragment,
        uint256 currentSupply
    );

    event BaseTokenSet(address indexed baseToken);
    event LiquidityPoolSet(address indexed liquidityPool);
    event APRParamsSet(uint256 fixedAPR, uint256 dynamicAPRMinCap, uint256 dynamicAPRMaxCap, uint256 dynamicAPRConstant);
    event RebaseIntervalSet(uint256 rebaseInterval);
    event StakeTaxSet(uint256 stakeTax);
    event UnstakeTaxSet(uint256 unstakeTax);
    event StakeStartTimeSet(uint256 stakeStartTime);
    event TreasurySet(address indexed treasury);

    constructor(
        address _baseToken, 
        address _liquidityPool, 
        address _treasury,
        uint256 _stakeStartTime
    ) Ownable(msg.sender) {
        baseToken = _baseToken;
        liquidityPool = _liquidityPool;
        treasury = _treasury;
        stakeStartTime = _stakeStartTime;

        maxSupply = IERC20MintableBurnable(baseToken).totalSupply() + 1 ether;
        initialMaxSupply = maxSupply;
        maxGons = MAX_UINT256 - (MAX_UINT256 % maxSupply);
        gonsPerFragment = maxGons / maxSupply;
        _mint(address(this), 1 ether);

        warmupPeriod = 60;

        emit BaseTokenSet(_baseToken);
        emit LiquidityPoolSet(_liquidityPool);
        emit TreasurySet(_treasury);
        emit StakeStartTimeSet(_stakeStartTime);
    }

    function setBaseToken(address _baseToken) external onlyOwner {
        baseToken = _baseToken;
        emit BaseTokenSet(_baseToken);
    }

    function setLiquidityPool(address _liquidityPool) external onlyOwner {
        liquidityPool = _liquidityPool;
        emit LiquidityPoolSet(_liquidityPool);
    }

    function setAprParameters(
        uint256 _fixedAPR,
        uint256 _dynamicAPRMinCap,
        uint256 _dynamicAPRMaxCap,
        uint256 _dynamicAPRConstant
    ) external onlyOwner {
        require(_dynamicAPRMinCap <= _dynamicAPRMaxCap, "Min cap higher than max cap");
        fixedAPR = _fixedAPR;
        dynamicAPRMinCap = _dynamicAPRMinCap;
        dynamicAPRMaxCap = _dynamicAPRMaxCap;
        dynamicAPRConstant = _dynamicAPRConstant;

        emit APRParamsSet(_fixedAPR, _dynamicAPRMinCap, _dynamicAPRMaxCap, _dynamicAPRConstant);
    }

    function setRebaseInterval(uint256 _rebaseInterval) external onlyOwner {
        rebaseInterval = _rebaseInterval;
        emit RebaseIntervalSet(_rebaseInterval);
    }

    function setStakeTax(uint256 _stakeTax) external onlyOwner {
        require(_stakeTax <= MAX_STAKE_TAX, "Stake tax too high");
        stakeTax = _stakeTax;
        emit StakeTaxSet(_stakeTax);
    }

    function setUnstakeTax(uint256 _unstakeTax) external onlyOwner {
        require(_unstakeTax <= MAX_UNSTAKE_TAX, "Unstake tax too high");
        unstakeTax = _unstakeTax;
        emit UnstakeTaxSet(_unstakeTax);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    function setStakeStartTime(uint256 _stakeStartTime) external onlyOwner {
        require(block.timestamp < stakeStartTime, "Staking already started");
        stakeStartTime = _stakeStartTime;
        emit StakeStartTimeSet(_stakeStartTime);
    }

    function setWarmupPeriod(uint256 _warmupPeriod) external onlyOwner {
        require(_warmupPeriod > 0, "Warmup period too low");
        require(_warmupPeriod <= 1 days, "Warmup period too high");
        warmupPeriod = _warmupPeriod;
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        uint256 gonsToAdd = amount * gonsPerFragment;
        totalGons += gonsToAdd;
        totalSupplyTokens += amount;
        _gonBalances[account] += gonsToAdd;

        emit Mint(account, amount, gonsToAdd, gonsPerFragment, totalSupplyTokens);

        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: burn from the zero address");

        uint256 gonsToRemove = amount * gonsPerFragment;
        totalGons -= gonsToRemove;
        totalSupplyTokens -= amount;
        _gonBalances[account] -= gonsToRemove;

        emit Burn(account, amount, gonsToRemove, gonsPerFragment, totalSupplyTokens);

        emit Transfer(account, address(0), amount);
    }

    function rebase() public {
        if (block.timestamp < stakeStartTime) return;

        uint256 timeToUse = lastRebaseTime > 0 ? lastRebaseTime : stakeStartTime;
        uint256 rebaseCount = (block.timestamp - timeToUse) / rebaseInterval;
        if (rebaseCount == 0) return;

        uint256 fixedApr = getFixedAPR();
        uint256 dynamicApr = getDynamicAPR();
        uint256 finalApr = fixedApr + dynamicApr;

        uint256 intervalsPerYear = ONE_YEAR / rebaseInterval;
        uint256 intervalAPR = finalApr / intervalsPerYear;
        uint256 supplyDelta = (maxSupply * intervalAPR) / SCALE / 100;

        if (supplyDelta == 0) {
            lastRebaseTime = timeToUse + rebaseInterval * rebaseCount;
            return;
        }

        if (supplyDelta > maxSupply) {
            supplyDelta = maxSupply;
        }

        maxSupply += supplyDelta;
        gonsPerFragment = maxGons / maxSupply;

        totalSupplyTokens = totalGons / gonsPerFragment; 
        lastRebaseTime = timeToUse + rebaseInterval * rebaseCount;

        emit Rebase(
            fixedApr, 
            dynamicApr, 
            intervalAPR, 
            timeToUse, 
            rebaseCount, 
            maxSupply,
            supplyDelta,
            gonsPerFragment,
            totalSupplyTokens 
        );
    }

    function stake(uint256 amount) external {
        rebase();

        require(IERC20(baseToken).transferFrom(msg.sender, address(this), amount), "Transfer failed");

        uint256 taxAmount = (amount * stakeTax) / PERCENTAGE_BASE;
        uint256 netAmount = amount - taxAmount;

        IERC20MintableBurnable(baseToken).burn(netAmount);
        if (taxAmount > 0) {
            IERC20(baseToken).transfer(treasury, taxAmount);
        }

        _mint(msg.sender, netAmount);

        if (warmupPeriod > 0) {
            stakeTimes[msg.sender] = block.timestamp;
        }
        
        emit Stake(msg.sender, amount, taxAmount, netAmount);
    }

    function unstake(uint256 amount) external {
        require(block.timestamp - stakeTimes[msg.sender] >= warmupPeriod, "Warmup period not over");

        rebase();

        uint256 gonsToRemove = amount * gonsPerFragment;
        require(_gonBalances[msg.sender] >= gonsToRemove, "Insufficient balance");

        _burn(msg.sender, amount);
        IERC20MintableBurnable(baseToken).mint(address(this), amount);

        uint256 taxAmount = (amount * unstakeTax) / PERCENTAGE_BASE;
        uint256 netAmount = amount - taxAmount;

        IERC20(baseToken).transfer(msg.sender, netAmount);
        if (taxAmount > 0) {
            IERC20(baseToken).transfer(treasury, taxAmount);
        }

        emit Unstake(msg.sender, amount, taxAmount, netAmount);
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        require(_gonBalances[sender] >= amount * gonsPerFragment, "ERC20: transfer amount exceeds balance");
        require(sender == address(0) || recipient != address(this), "ERC20: transfer to staking contract");

        rebase();

        uint256 taxAmount = ((stakeTax + unstakeTax) * amount) / PERCENTAGE_BASE;
        uint256 netAmount = amount - taxAmount;

        uint256 gonsToTransfer = netAmount * gonsPerFragment;
        uint256 gonsTaxAmount = taxAmount * gonsPerFragment;

        _gonBalances[sender] -= (gonsToTransfer + gonsTaxAmount);
        _gonBalances[recipient] += gonsToTransfer;
        if (gonsTaxAmount > 0) {
            _gonBalances[treasury] += gonsTaxAmount;
        }

        emit Transfer(sender, recipient, netAmount);
    }

    function getFixedAPR() public view returns (uint256) {
        return fixedAPR;
    }

    function getDynamicAPR() public view returns (uint256) {
        uint256 totalStaked = totalSupplyTokens;
        uint256 lpBalance = IERC20(baseToken).balanceOf(liquidityPool);

        if (lpBalance <= 0) {
            revert("LP balance zero");
        }
        if (dynamicAPRConstant <= 0) {
            revert("Dynamic APR constant zero");
        }

        uint256 ratio = (totalStaked * SCALE) / lpBalance;

        if (ratio > 10 * SCALE) {
            ratio = 10 * SCALE;
        }

        uint256 scaledRatio = (ratio * dynamicAPRConstant) / SCALE;
        uint256 logInput = SCALE + scaledRatio;

        uint256 logValue = log10(logInput);

        uint256 apyValue = dynamicAPRMaxCap -
            ((dynamicAPRMaxCap - dynamicAPRMinCap) * logValue) /
            log10(dynamicAPRConstant * 10);

        if (apyValue < dynamicAPRMinCap) {
            apyValue = dynamicAPRMinCap;
        }

        return apyValue;
    }

    function getFinalAPR() public view returns (uint256) {
        return getFixedAPR() + getDynamicAPR();
    }

    function log10(uint256 x) internal view returns (uint256) {
        if (x <= 0) {
            revert("Log zero");
        }
        uint256 result = 0;
        while (x >= 10 * SCALE) {
            x /= 10;
            result += SCALE;
        }
        for (uint8 i = 0; i < 18; ++i) {
            x = (x * x) / SCALE;
            if (x >= 10 * SCALE) {
                x /= 10;
                result += SCALE / (2 ** (i + 1));
            }
        }
        return result;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _gonBalances[account] / gonsPerFragment;
    }

    function totalSupply() public view override returns (uint256) {
        return totalSupplyTokens;
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, currentAllowance - amount);

        return true;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function timeTillNextRebase() public view returns (uint256) {
        if (block.timestamp < stakeStartTime) {
            return stakeStartTime - block.timestamp;
        }
        return rebaseInterval - ((block.timestamp - stakeStartTime) % rebaseInterval);
    }

    function totalTokensAtNextRebase() public view returns (uint256) {
        uint256 fixedApr = getFixedAPR();
        uint256 dynamicApr = getDynamicAPR();
        uint256 finalApr = fixedApr + dynamicApr;

        uint256 intervalsPerYear = ONE_YEAR / rebaseInterval;
        uint256 intervalAPR = finalApr / intervalsPerYear;
        uint256 supplyDelta = (totalSupplyTokens * intervalAPR) / SCALE / 100;

        return supplyDelta;
    }

    function tokensForAddressAtNextRebase(address account) public view returns (uint256) {
        uint256 supplyDelta = totalTokensAtNextRebase();
        uint256 userBalance = balanceOf(account);
        uint256 userShare = (userBalance * SCALE) / totalSupplyTokens;

        return (supplyDelta * userShare) / SCALE / 100;
    }

    function tokensDeductedForUnstaking(uint256 amount) public view returns (uint256) {
        uint256 taxAmount = (amount * unstakeTax) / PERCENTAGE_BASE;
        return taxAmount;
    }

    function tokensDeductedForStaking(uint256 amount) public view returns (uint256) {
        uint256 taxAmount = (amount * stakeTax) / PERCENTAGE_BASE;
        return taxAmount;
    }

    function index() public view returns (uint256) {
        return balanceOf(address(this));
    }

    function totalTokensRewarded() public view returns (uint256) {
        return maxSupply - initialMaxSupply;
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(this), "Cannot withdraw staking token");
        IERC20(token).transfer(to, amount);
    }
    
    function emergencyEthWithdraw(address to, uint256 amount) external onlyOwner {
        payable(to).transfer(amount);
    }
}