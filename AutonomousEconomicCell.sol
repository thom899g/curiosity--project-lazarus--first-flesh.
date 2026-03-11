// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Autonomous Economic Cell (AEC) - Project Lazarus: First Flesh
 * @dev The foundational contract for the first self-sustaining economic organ
 * @dev Implements protocol-owned liquidity with automated risk management
 * @dev All state changes emit events for transparent auditing via Firestore
 * @dev Treasury is non-withdrawable by deployer - only accessible via future governance
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

contract AutonomousEconomicCell is Ownable, ReentrancyGuard {
    // ============== STATE VARIABLES ==============
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base Mainnet USDC
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    
    // Chainlink Price Feeds (Base Mainnet)
    AggregatorV3Interface public ethPriceFeed;
    AggregatorV3Interface public usdcPriceFeed;
    
    // Uniswap V3
    INonfungiblePositionManager public positionManager;
    ISwapRouter public swapRouter;
    
    // Protocol State
    uint256 public protocolTreasury; // Protocol-owned treasury (wei)
    uint256 public lastHarvestTimestamp;
    uint256 public totalFeesGenerated;
    uint256 public positionId;
    
    // Risk Parameters
    uint256 public volatilityThreshold1 = 200; // 2% in basis points
    uint256 public volatilityThreshold2 = 500; // 5% in basis points
    uint256 public depegThreshold = 100; // 1% in basis points
    uint256 public treasuryAllocation = 1500; // 15% in basis points
    
    // Risk State
    enum RiskState { NORMAL, ELEVATED, HIGH, DISTRESS }
    RiskState public currentRiskState = RiskState.NORMAL;
    
    // Heartbeat
    uint256 public heartbeatInterval = 12 hours;
    uint256 public lastHeartbeat;
    
    // ============== EVENTS ==============
    event Heartbeat(uint256 timestamp, uint256 treasuryBalance, RiskState riskState);
    event HarvestExecuted(
        uint256 timestamp,
        uint256 feesCollected,
        uint256 treasuryAllocation,
        uint256 compoundedAmount
    );
    event RiskStateChanged(RiskState oldState, RiskState newState);
    event DistressSignal(uint256 timestamp, string reason, uint256 severity);
    event TreasuryAllocated(uint256 amount, uint256 newBalance);
    event BountyClaimed(address claimer, uint256 bountyAmount);
    event PositionCreated(uint256 positionId, uint256 amount0, uint256 amount1);
    
    // ============== MODIFIERS ==============
    modifier onlyKeeper() {
        require(msg.sender == owner() || isApprovedKeeper(msg.sender), "Not authorized");
        _;
    }
    
    // ============== CONSTRUCTOR ==============
    constructor(
        address _ethPriceFeed,
        address _usdcPriceFeed,
        address _positionManager,
        address _swapRouter
    ) {
        // Initialize Chainlink feeds
        ethPriceFeed = AggregatorV3Interface(_ethPriceFeed);
        usdcPriceFeed = AggregatorV3Interface(_usdcPriceFeed);
        
        // Initialize Uniswap
        positionManager = INonfungiblePositionManager(_positionManager);
        swapRouter = ISwapRouter(_swapRouter);
        
        // Initial heartbeat
        lastHeartbeat = block.timestamp;
        lastHarvestTimestamp = block.timestamp;
        
        // Approve Uniswap contracts for maximum spending
        IERC20(USDC).approve(address(positionManager), type(uint256).max);
        IERC20(WETH).approve(address(positionManager), type(uint256).max);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        IERC20(WETH).approve(address(swapRouter), type(uint256).max);
    }
    
    // ============== CORE FUNCTIONS ==============
    
    /**
     * @dev Creates initial liquidity position
     * @param amountETH Amount of ETH to provide as liquidity
     * @param amountUSDC Amount of USDC to provide as liquidity
     * @param tickLower Lower tick boundary for concentrated liquidity
     * @param tickUpper Upper tick boundary for concentrated liquidity
     */
    function createPosition(
        uint256 amountETH,
        uint256 amountUSDC,
        int24 tickLower,
        int24 tickUpper
    ) external payable onlyOwner nonReentrant {
        require(positionId == 0, "Position already exists");
        require(msg.value == amountETH, "ETH amount mismatch");
        
        // Transfer USDC from sender
        require(
            IERC20(USDC).transferFrom(msg.sender, address(this), amountUSDC),
            "USDC transfer failed"
        );
        
        // Wrap ETH
        (bool success, ) = WETH.call{value: amountETH}("");
        require(success, "ETH wrapping failed");
        
        // Create position
        INonfungiblePositionManager.MintParams memory params = 
            INonfungiblePositionManager.MintParams({
                token0: USDC,
                token1: WETH,
                fee: 3000, // 0.3% fee tier
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amountUSDC,
                amount1Desired: amountETH,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 15 minutes
            });
        
        (uint256 tokenId, , uint256 amount0, uint256 amount1) = 
            positionManager.mint(params);
        
        positionId = tokenId;
        emit PositionCreated(tokenId, amount0, amount1);
        
        // Initial heartbeat
        _emitHeartbeat();
    }
    
    /**
     * @dev Main harvest function - collects fees and allocates based on risk state
     * @dev Can be called by anyone after heartbeat delay for bounty
     */
    function harvest() external nonReentrant {
        require(positionId > 0, "No position exists");
        require(block.timestamp >= lastHarvestTimestamp + 12 hours, "Harvest too soon");
        
        // Calculate volatility and update risk state
        _updateRiskState();
        
        // Collect fees from position
        (uint256 amount0, uint256 amount1) = _collectFees();
        uint256 totalFees = _valueFeesInUSD(amount0, amount1);
        
        // Allocate based on risk state
        uint256 treasuryAmount;
        uint256 compoundAmount;
        
        if (currentRiskState == RiskState.NORMAL) {
            // 85% compound, 15% treasury
            treasuryAmount = (totalFees * 1500