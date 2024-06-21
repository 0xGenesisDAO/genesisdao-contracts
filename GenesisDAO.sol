// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

contract GenesisDAO is ERC20, Ownable
{
    address public treasury;
    address public stakingContract;
    address public presaleContract;
    bool public enableTrading = false;
    bool private _stakingContractSet = false;
    bool private _presaleContractSet = false;
    mapping(address => bool) private _isExcludedFromTaxes;
    mapping(address => bool) private _liquidityPools;
    address private _pairAddress;
    IUniswapV2Router02 public router;
    address private _routerAddr;

    uint256 public buyTax = 2;
    uint256 public sellTax = 5;
    uint256 public taxLiquidatePercentage = 30;

    receive() external payable {}

    constructor(address initialOwner, address uniswapRouterAddress, address _treasury)
        ERC20("Genesis", "GEN")
        Ownable(initialOwner)
    {
        treasury = _treasury;

        // Set up initial pair
        router = IUniswapV2Router02(uniswapRouterAddress);
        _routerAddr = uniswapRouterAddress;
        _pairAddress = IUniswapV2Factory(router.factory()).createPair(
            address(this),
            router.WETH()
        );
        _setLiquidityPool(address(_pairAddress), true);
    
        excludeFromTaxes(owner(), true);
        excludeFromTaxes(address(this), true);
        excludeFromTaxes(address(0xdead), true);
        excludeFromTaxes(treasury, true);

        _mint(owner(), 1_000_000_000 * 1e18);

        // Approve contract to swap for tax mechanism
        _approve(address(this), address(router), 1_000_000_000 * 1e18);
        _approve(owner(), address(router), 1_000_000_000 * 1e18);
    }    

    function updateBuyTax(uint256 _buyTax) external onlyOwner {
        require(_buyTax <= 5, "Cannot set tax higher than 5%");
        buyTax = _buyTax;
    }

    function updateSellTax(uint256 _sellTax) external onlyOwner {
        require(_sellTax <= 20, "Cannot set tax higher than 20%");
        sellTax = _sellTax;
    }

    function updateTaxLiquidationPercentage(uint256 _taxLiqPercentage) external onlyOwner {
        require(_taxLiqPercentage <= 40, "Cannot set tax liquidate percentage higher than 40%");
        taxLiquidatePercentage = _taxLiqPercentage;
    }

    function updateTaxes(uint256 _buyTax, uint256 _sellTax) external onlyOwner 
    {
        require(_sellTax <= 20 && _buyTax <= 5, "Cannot set taxes higher than 20 and 5% respectively");
        buyTax = _buyTax;
        sellTax = _sellTax;
    }

    function _update(address from, address to, uint256 amount) internal override 
    {
        if (amount == 0) 
        {
            super._update(from, to, 0);
            return;
        }

        if (enableTrading == false && from != presaleContract && to != presaleContract)
        {
            revert("Token has not been launched yet!");
        }

        bool takeTax = true;

        if (_isExcludedFromTaxes[from] || _isExcludedFromTaxes[to]) 
        {
            takeTax = false;
        }

        uint256 taxes = 0;

        if (takeTax) {
            if (_liquidityPools[to] && sellTax > 0) {
                taxes = (amount * sellTax) / 100;
            } else if (_liquidityPools[from] && buyTax > 0) {
                taxes = (amount * buyTax) / 100;
            }

            amount -= taxes;
        }        

        if (taxes > 0)
        {
            // send x percentage to treasury in tokens.
            uint256 tokenTax = (taxes * (100 - taxLiquidatePercentage)) / 100;            
            super._update(from, treasury, tokenTax);         
                        
            // send remainder to token contract.
            uint256 ethTax = taxes - tokenTax;
            if (ethTax > 0) 
            {
                super._update(from, address(this), ethTax);
            }
        }

        // on a sell, liquidate any tokens in the token contract for ETH and send to treasury.
        if (_liquidityPools[to] && takeTax)
        {
            liquidateTokenTax();
        }

        super._update(from, to, amount);
    }   

    function liquidateTokenTax() internal 
    {
        uint tokenAmount = balanceOf(address(this));
        if (tokenAmount > 0) 
        {        
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = router.WETH();
            _approve(address(this), address(_routerAddr), tokenAmount);

            router.swapExactTokensForETH(
            tokenAmount,
            0,
            path,
            treasury,
            block.timestamp
            );
        }
    }

    function setLiquidityPool(address pair, bool isLiquidityPool) public onlyOwner 
    {
        _setLiquidityPool(pair, isLiquidityPool);
    }

    function _setLiquidityPool(address pair, bool isLiquidityPool) private 
    {
        _liquidityPools[pair] = isLiquidityPool;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == stakingContract);
        _mint(to, amount);
    }

    function setStakingContract(address stakingContract_) external onlyOwner {
        require(_stakingContractSet == false, "Staking contract can only be set once, and is immutable afterwards");
        stakingContract = stakingContract_;
        excludeFromTaxes(stakingContract, true);
        _stakingContractSet = true;
    }

    function setPresaleContract(address presaleContract_) external onlyOwner {
        require(_presaleContractSet == false, "Presale contract can only be set once, and is immutable afterwards");
        presaleContract = presaleContract_;
        excludeFromTaxes(presaleContract, true);
        _presaleContractSet = true;
    }

    function setEnableTrading() external onlyOwner {
        require(_presaleContractSet == true, "Presale contract must be set up before enabling trades, otherwise there cannot be any liquidity yet");
        enableTrading = true;
    }

    function burn(uint256 amount) external 
    {
        _burn(msg.sender, amount);
    }

    function excludeFromTaxes(address account, bool excluded) public onlyOwner 
    {
        _isExcludedFromTaxes[account] = excluded;
    }

    function emergencyWithdraw(address token, address to, uint256 amount) public onlyOwner {
        IERC20(token).transfer(to, amount);
    }
    
    function emergencyEthWithdraw(address to, uint256 amount) public onlyOwner {
        payable(to).transfer(amount);
    }
}