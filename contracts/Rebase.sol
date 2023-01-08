// SPDX-License-Identifier: Unlicensed

pragma solidity 0.7.4;

import "../access/Ownable.sol";
import "../contracts/math/Math.sol";
import "../contracts/math/SafeMath.sol";
import "../contracts/ERC20/ERC20.sol";
import "../contracts/interfaces/IRebaseFactory.sol";
import "../contracts/interfaces/IRebasePair.sol";
import "../contracts/interfaces/IRebaseRouter01.sol";
import "../contracts/interfaces/IRebaseRouter02.sol";

contract Rebase is ERC20, Ownable {
    using SafeMath for uint256;
    using Math for uint256;

    uint256 private constant DECIMALS = 18;
    uint256 private constant MAX_UINT256 = ~uint256(0);
    uint256 private constant INITIAL_FRAGMENTS_SUPPLY =
        1000000000 * 10 ** DECIMALS;
    uint256 private constant TOTAL_GONS =
        MAX_UINT256 - (MAX_UINT256 % INITIAL_FRAGMENTS_SUPPLY);
    address private constant DEAD_ADDR =
        0x000000000000000000000000000000000000dEaD;
    uint256 private constant MAX_SUPPLY = ~uint256(0);
    uint256 private constant SECONDS_PER_DAY = 86400;

    uint256 public constant LAUNCH_FEE_MULTIPLIER = 3;
    uint256 public constant LAUNCH_FEE_DURATION = 5;
    uint256 public constant TAX_BRACKET_MULTIPLIER = 5;
    uint256 public constant MAX_TAX_BRACKET = 6; // max bracket is 6. used to multiply with the taxBracketMultiplier
    uint256 public constant REBASE_INTERVAL = 1800;
    uint256 public constant REWARD_YIELD = 457089;
    uint256 public constant REWARD_YIELD_DENOM = 1000000000;

    uint256 private constant MAX_TRANSACTION = 5;
    uint256 private constant MAX_TRANSACTION_DENOM = 1000;
    uint256 private constant SWAP_THRESHOLD = 1;
    uint256 private constant SWAP_THRESHOLD_DENOM = 1000;
    uint256 private constant FEE_DENOMINATOR = 100;

    IRebaseRouter02 public router;
    address public pair;

    address[] public _markerPairs;
    uint256 public _markerPairCount;

    mapping(address => bool) public _isFeeExempt;
    mapping(address => bool) public automatedMarketMakerPairs;

    bool public swapEnabled = true;
    bool public autoRebaseEnabled = true;
    bool public transferFeeEnabled = true;
    bool public taxBracketFeeEnabled = false;
    bool public launchFeeEnabled = true;

    uint256 public swapThreshold =
        calculateAmount(
            INITIAL_FRAGMENTS_SUPPLY,
            SWAP_THRESHOLD,
            SWAP_THRESHOLD_DENOM
        ); // default 0.1%
    uint256 public maxSellTransactionAmount =
        calculateAmount(
            INITIAL_FRAGMENTS_SUPPLY,
            MAX_TRANSACTION,
            MAX_TRANSACTION_DENOM
        ); // default 0.5% of totalSupply.
    uint256 public maxBuyTransactionAmount =
        calculateAmount(
            INITIAL_FRAGMENTS_SUPPLY,
            MAX_TRANSACTION,
            MAX_TRANSACTION_DENOM
        ); // default 0.5% of totalSupply.
    uint256 public nextRebase = block.timestamp + 30 days; // to be updated once confirmed listing time
    uint256 public rebaseCount = 0;

    // Fee receiver
    address public liquidityReceiver =
        0x1F2C03A848f9F70dd66a45FFC56cFb32a53D01c1;
    address public treasuryReceiver =
        0x1BeFa4eA1D80fd83d7b9C730280d7085E74756FF;
    address public rfvReceiver = 0xd00710Da275f683D38C2892455993cC0D87f09C2;

    // Fee
    uint256 public constant LIQUIDITY_FEE = 5;
    uint256 public constant TREASURY_FEE = 5;
    uint256 public constant RFV_FEE = 5;
    uint256 public constant BURN_FEE = 5;

    uint256 public launchFee = LAUNCH_FEE_DURATION.mul(LAUNCH_FEE_MULTIPLIER);
    uint256 public totalFee = LIQUIDITY_FEE.add(TREASURY_FEE).add(RFV_FEE);

    bool inSwap;

    modifier swapping() {
        inSwap = true;
        _;
        inSwap = false;
    }

    uint256 private _totalSupply;
    uint256 private _gonsPerFragment;

    mapping(address => uint256) private _gonBalances;
    mapping(address => mapping(address => uint256)) private _allowedFragments;

    constructor() ERC20("Accumulator", "ACC") {
        router = IRebaseRouter02(0x6a3ee34d88186436C310667571FF3F1d1539F721);
        pair = IRebaseFactory(router.factory()).createPair(
            address(this),
            router.WETH()
        );

        _allowedFragments[address(this)][address(router)] = uint256(-1);
        _allowedFragments[address(this)][pair] = uint256(-1);
        _allowedFragments[address(this)][address(this)] = uint256(-1);

        setAutomatedMarketMakerPair(pair, true);

        _totalSupply = INITIAL_FRAGMENTS_SUPPLY;
        _gonBalances[msg.sender] = TOTAL_GONS;
        _gonsPerFragment = TOTAL_GONS.div(_totalSupply);

        _isFeeExempt[treasuryReceiver] = true;
        _isFeeExempt[rfvReceiver] = true;
        _isFeeExempt[address(this)] = true;
        _isFeeExempt[msg.sender] = true;

        emit Transfer(address(0), msg.sender, _totalSupply);
    }

    receive() external payable {}

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function allowance(
        address owner_,
        address spender
    ) public view override returns (uint256) {
        return _allowedFragments[owner_][spender];
    }

    function balanceOf(address who) public view override returns (uint256) {
        return _gonBalances[who].div(_gonsPerFragment);
    }

    function markerPairAddress(uint256 value) public view returns (address) {
        return _markerPairs[value];
    }

    function shouldRebase() internal view returns (bool) {
        return nextRebase <= block.timestamp;
    }

    function shouldTakeFee(
        address from,
        address to
    ) internal view returns (bool) {
        if (_isFeeExempt[from] || _isFeeExempt[to]) {
            return false;
        } else if (transferFeeEnabled) {
            return true;
        } else {
            return (automatedMarketMakerPairs[from] ||
                automatedMarketMakerPairs[to]);
        }
    }

    function shouldSwapBack() internal view returns (bool) {
        return
            !automatedMarketMakerPairs[msg.sender] &&
            !inSwap &&
            swapEnabled &&
            _gonBalances[address(this)].div(_gonsPerFragment) >= swapThreshold;
    }

    function getGonBalances()
        external
        view
        returns (bool thresholdReturn, uint256 gonBalanceReturn)
    {
        thresholdReturn =
            _gonBalances[address(this)].div(_gonsPerFragment) >= swapThreshold;
        gonBalanceReturn = _gonBalances[address(this)].div(_gonsPerFragment);
    }

    function getCirculatingSupply() public view returns (uint256) {
        return
            (
                TOTAL_GONS.sub(_gonBalances[DEAD_ADDR]).sub(
                    _gonBalances[address(0)]
                )
            ).div(_gonsPerFragment);
    }

    function getTokensInLPCirculation() public view returns (uint256) {
        uint112 reserve0;
        uint112 reserve1;
        uint32 blockTimestampLast;
        address token0;
        address token1;
        IRebasePair iDexFeeCalculator;
        uint256 LPTotal;

        for (uint256 i = 0; i < _markerPairs.length; i++) {
            iDexFeeCalculator = IRebasePair(_markerPairs[i]);
            (reserve0, reserve1, blockTimestampLast) = iDexFeeCalculator
                .getReserves();

            token0 = iDexFeeCalculator.token0();
            token1 = iDexFeeCalculator.token1();

            if (token0 == address(this)) {
                LPTotal = LPTotal.add(reserve0);
                //first one
            } else if (token1 == address(this)) {
                LPTotal = LPTotal.add(reserve1);
            }
        }

        return LPTotal;
    }

    function getCurrentTaxBracket(
        address _address
    ) public view returns (uint256) {
        //gets the total balance of the user
        uint256 userBalance = balanceOf(_address);

        //calculate the percentage
        uint256 totalCap = userBalance.mul(100).div(getTokensInLPCirculation());

        //calculate what is smaller, and use that
        uint256 _bracket = Math.min(totalCap, MAX_TAX_BRACKET);

        //multiply the bracket with the multiplier
        _bracket = _bracket.mul(TAX_BRACKET_MULTIPLIER);

        return _bracket;
    }

    function manualSync() external {
        for (uint256 i = 0; i < _markerPairs.length; i++) {
            IRebasePair(_markerPairs[i]).sync();
        }
    }

    function transfer(
        address to,
        uint256 value
    ) public override returns (bool) {
        require(to != address(0), "Zero address");
        _transferFrom(msg.sender, to, value);
        return true;
    }

    function basicTransfer(
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        uint256 gonAmount = amount.mul(_gonsPerFragment);
        _gonBalances[from] = _gonBalances[from].sub(gonAmount);
        _gonBalances[to] = _gonBalances[to].add(gonAmount);

        emit Transfer(from, to, amount);

        return true;
    }

    function _transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) internal returns (bool) {
        bool excludedAccount = _isFeeExempt[sender] || _isFeeExempt[recipient];

        if (automatedMarketMakerPairs[recipient] && !excludedAccount) {
            require(
                amount <= maxSellTransactionAmount,
                "Exceeded max sell limit"
            );
        }

        if (automatedMarketMakerPairs[sender] && !excludedAccount) {
            require(
                amount <= maxBuyTransactionAmount,
                "Exceeded max buy limit"
            );
        }

        if (inSwap) {
            return basicTransfer(sender, recipient, amount);
        }

        uint256 gonAmount = amount.mul(_gonsPerFragment);

        if (shouldSwapBack()) {
            swapBack();
        }

        _gonBalances[sender] = _gonBalances[sender].sub(gonAmount);

        uint256 gonAmountReceived = shouldTakeFee(sender, recipient)
            ? takeFee(sender, recipient, gonAmount)
            : gonAmount;

        _gonBalances[recipient] = _gonBalances[recipient].add(
            gonAmountReceived
        );

        emit Transfer(
            sender,
            recipient,
            gonAmountReceived.div(_gonsPerFragment)
        );

        if (shouldRebase() && autoRebaseEnabled) {
            rebase();
        }

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        require(to != address(0), "Zero address");

        if (_allowedFragments[from][msg.sender] != uint256(-1)) {
            _allowedFragments[from][msg.sender] = _allowedFragments[from][
                msg.sender
            ].sub(value, "Insufficient Allowance");
        }

        _transferFrom(from, to, value);
        return true;
    }

    function swapAndLiquify(uint256 contractTokenBalance) internal {
        uint256 half = contractTokenBalance.div(2);
        uint256 otherHalf = contractTokenBalance.sub(half);

        uint256 initialBalance = address(this).balance;
        swapTokensForEth(half, address(this));

        uint256 newBalance = address(this).balance.sub(initialBalance);
        addLiquidity(otherHalf, newBalance);

        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function addLiquidity(uint256 tokenAmount, uint256 amount) internal {
        router.addLiquidityETH{value: amount}(
            address(this),
            tokenAmount,
            0,
            0,
            liquidityReceiver,
            block.timestamp
        );
    }

    function swapTokensForEth(uint256 tokenAmount, address receiver) internal {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            receiver,
            block.timestamp
        );
    }

    function swapBack() internal swapping {
        uint256 ethBalance = address(this).balance;
        uint256 tokenBalance = _gonBalances[address(this)].div(
            _gonsPerFragment
        );
        uint256 amountToLiquify = calculateAmount(
            tokenBalance,
            LIQUIDITY_FEE,
            totalFee
        );
        uint256 amountToRFV = calculateAmount(tokenBalance, RFV_FEE, totalFee);
        uint256 amountToTreasury = calculateAmount(
            tokenBalance,
            TREASURY_FEE,
            totalFee
        );

        swapAndLiquify(amountToLiquify);
        swapTokensForEth(amountToRFV.add(amountToTreasury), address(this));

        uint256 newEthBalance = address(this).balance.sub(ethBalance);

        (bool success, ) = payable(rfvReceiver).call{
            value: calculateAmount(
                newEthBalance,
                RFV_FEE,
                RFV_FEE.add(TREASURY_FEE)
            ),
            gas: 300000
        }("");

        (success, ) = payable(treasuryReceiver).call{
            value: calculateAmount(
                newEthBalance,
                TREASURY_FEE,
                RFV_FEE.add(TREASURY_FEE)
            ),
            gas: 300000
        }("");

        emit SwapBack(
            tokenBalance,
            amountToLiquify,
            amountToRFV,
            amountToTreasury
        );
    }

    function takeFee(
        address sender,
        address recipient,
        uint256 gonAmount
    ) internal returns (uint256) {
        uint256 _totalFee = totalFee;
        uint256 _burnFee = 0;

        // Additional fees for sell transactions
        if (automatedMarketMakerPairs[recipient]) {
            // Add launch fee when enabled
            if (launchFeeEnabled) _totalFee = _totalFee.add(launchFee);

            // Add tax bracket if enabled, only applicable to sell
            if (taxBracketFeeEnabled)
                _totalFee = _totalFee.add(getCurrentTaxBracket(sender));

            _burnFee = calculateAmount(gonAmount, BURN_FEE, FEE_DENOMINATOR);
        }

        // Send burn fee to dead address
        if (_burnFee > 0) {
            _gonBalances[DEAD_ADDR] = _gonBalances[DEAD_ADDR].add(_burnFee);
            emit Transfer(sender, DEAD_ADDR, _burnFee.div(_gonsPerFragment));
        }

        uint256 feeAmount = calculateAmount(
            gonAmount,
            _totalFee,
            FEE_DENOMINATOR
        );
        _gonBalances[address(this)] = _gonBalances[address(this)].add(
            feeAmount
        );

        emit Transfer(sender, address(this), feeAmount.div(_gonsPerFragment));
        return gonAmount.sub(feeAmount.add(_burnFee));
    }

    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) public override returns (bool) {
        uint256 oldValue = _allowedFragments[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedFragments[msg.sender][spender] = 0;
        } else {
            _allowedFragments[msg.sender][spender] = oldValue.sub(
                subtractedValue
            );
        }
        emit Approval(
            msg.sender,
            spender,
            _allowedFragments[msg.sender][spender]
        );
        return true;
    }

    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) public override returns (bool) {
        _allowedFragments[msg.sender][spender] = _allowedFragments[msg.sender][
            spender
        ].add(addedValue);

        emit Approval(
            msg.sender,
            spender,
            _allowedFragments[msg.sender][spender]
        );
        return true;
    }

    function approve(
        address spender,
        uint256 value
    ) public override returns (bool) {
        _allowedFragments[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function rebase() internal {
        if (!inSwap) {
            uint256 circulatingSupply = getCirculatingSupply();
            uint256 supplyDelta = calculateAmount(
                circulatingSupply,
                REWARD_YIELD,
                REWARD_YIELD_DENOM
            );

            coreRebase(supplyDelta);
        }
    }

    function coreRebase(uint256 supplyDelta) internal returns (uint256) {
        uint256 epoch = block.timestamp;

        if (supplyDelta == 0) {
            emit LogRebase(epoch, _totalSupply);
            return _totalSupply;
        }

        if (_totalSupply > MAX_SUPPLY) {
            _totalSupply = MAX_SUPPLY;
        } else {
            _totalSupply = _totalSupply.add(uint256(supplyDelta));
        }

        _gonsPerFragment = TOTAL_GONS.div(_totalSupply);
        rebaseCount = rebaseCount.add(1);
        nextRebase = epoch.add(REBASE_INTERVAL);

        if (launchFeeEnabled) {
            updateLaunchPeriodFee();
        }

        updateMaxTransaction();
        updateSwapThreshold();

        emit LogRebase(epoch, _totalSupply);
        return _totalSupply;
    }

    function manualRebase() external onlyOwner {
        require(!inSwap, "Rebasing, try again");
        require(
            nextRebase <= block.timestamp,
            "Not in rebase allowed timeframe"
        );

        uint256 circulatingSupply = getCirculatingSupply();
        uint256 supplyDelta = calculateAmount(
            circulatingSupply,
            REWARD_YIELD,
            REWARD_YIELD_DENOM
        );

        updateMaxTransaction();
        updateSwapThreshold();

        emit LogManualRebase(circulatingSupply, block.timestamp);
        coreRebase(supplyDelta);
    }

    function calculateAmount(
        uint256 amount,
        uint256 numerator,
        uint256 denumerator
    ) internal pure returns (uint256) {
        return amount.mul(numerator).div(denumerator);
    }

    function updateSwapThreshold() internal {
        uint256 threshold = calculateAmount(
            _totalSupply,
            SWAP_THRESHOLD,
            SWAP_THRESHOLD_DENOM
        );

        swapThreshold = threshold;
    }

    function updateMaxTransaction() internal {
        uint256 maxTransaction = calculateAmount(
            _totalSupply,
            MAX_TRANSACTION,
            MAX_TRANSACTION_DENOM
        );

        maxBuyTransactionAmount = maxTransaction;
        maxSellTransactionAmount = maxTransaction;
    }

    function updateLaunchPeriodFee() internal {
        uint256 totalRebasePerDay = SECONDS_PER_DAY / REBASE_INTERVAL;
        uint256 dayCount = rebaseCount.div(totalRebasePerDay);
        uint256 totalLaunchFee = LAUNCH_FEE_DURATION.mul(LAUNCH_FEE_MULTIPLIER);

        if (dayCount < LAUNCH_FEE_DURATION) {
            launchFee = totalLaunchFee.sub(dayCount.mul(LAUNCH_FEE_MULTIPLIER));
        } else {
            launchFee = 0;
            launchFeeEnabled = false;
            taxBracketFeeEnabled = true;
        }
    }

    function setAutomatedMarketMakerPair(
        address _pair,
        bool _bool
    ) public onlyOwner {
        automatedMarketMakerPairs[_pair] = _bool;

        if (_bool) {
            _markerPairs.push(_pair);
            _markerPairCount++;
        } else {
            require(_markerPairs.length > 1, "Require more than 1 marketPair");
            for (uint256 i = 0; i < _markerPairs.length; i++) {
                if (_markerPairs[i] == _pair) {
                    _markerPairs[i] = _markerPairs[_markerPairs.length - 1];
                    _markerPairs.pop();
                    break;
                }
            }
        }

        emit SetAutomatedMarketMakerPair(_pair, _bool);
    }

    function setFeeExempt(address _addr, bool _bool) external onlyOwner {
        _isFeeExempt[_addr] = _bool;

        emit SetFeeExempt(_addr, _bool);
    }

    function setSwapBackEnabled(bool _bool) external onlyOwner {
        swapEnabled = _bool;
        emit SetSwapBackEnabled(_bool);
    }

    function setFeeReceivers(
        address _liquidityReceiver,
        address _treasuryReceiver,
        address _rfvReceiver
    ) external onlyOwner {
        require(
            _liquidityReceiver != address(0),
            "liquidityReceiver zero address"
        );
        require(
            _treasuryReceiver != address(0),
            "treasuryReceiver zero address"
        );
        require(_rfvReceiver != address(0), "rfvReceiver zero address");

        liquidityReceiver = _liquidityReceiver;
        treasuryReceiver = _treasuryReceiver;
        rfvReceiver = _rfvReceiver;

        emit SetFeeReceivers(
            _liquidityReceiver,
            _treasuryReceiver,
            _rfvReceiver
        );
    }

    function clearStuckBalance(address _receiver) external onlyOwner {
        require(_receiver != address(0), "Zero address");
        uint256 balance = address(this).balance;
        payable(_receiver).transfer(balance);
        emit ClearStuckBalance(balance, _receiver, block.timestamp);
    }

    function rescueToken(
        address tokenAddress,
        address to
    ) external onlyOwner returns (bool success) {
        uint256 _contractBalance = IERC20(tokenAddress).balanceOf(
            address(this)
        );

        emit RescueToken(tokenAddress, to, _contractBalance, block.timestamp);
        return ERC20(tokenAddress).transfer(to, _contractBalance);
    }

    function setAutoRebase(bool _bool) external onlyOwner {
        autoRebaseEnabled = _bool;
        emit SetAutoRebaseEnabled(_bool, block.timestamp);
    }

    function disableLaunchFee() external onlyOwner {
        launchFee = 0;
        launchFeeEnabled = false;
        taxBracketFeeEnabled = true;

        emit DisableLaunchFee(block.timestamp);
    }

    function setTaxBracketEnabled(bool _bool) external onlyOwner {
        taxBracketFeeEnabled = _bool;
        emit SetTaxBracketEnabled(_bool, block.timestamp);
    }

    function setNextRebase(uint256 _nextRebase) external onlyOwner {
        nextRebase = _nextRebase;
        emit SetNextRebase(_nextRebase, block.timestamp);
    }

    function setTransferFeeEnabled(bool _bool) external onlyOwner {
        transferFeeEnabled = _bool;
        emit SetTransferFeeEnabled(_bool, block.timestamp);
    }

    function setRouter(address _router) external onlyOwner {
        router = IRebaseRouter02(_router);
        _allowedFragments[address(this)][address(router)] = uint256(-1);

        emit SetRouter(_router, block.timestamp);
    }

    function setPair(address _pair) external onlyOwner {
        pair = _pair;
        _allowedFragments[address(this)][_pair] = uint256(-1);
        setAutomatedMarketMakerPair(pair, true);

        emit SetPair(_pair, block.timestamp);
    }

    event SwapBack(
        uint256 contractTokenBalance,
        uint256 amountToLiquify,
        uint256 amountToRFV,
        uint256 amountToTreasury
    );
    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 EthReceived,
        uint256 tokensIntoLiqudity
    );
    event SetFeeReceivers(
        address indexed _liquidityReceiver,
        address indexed _treasuryReceiver,
        address indexed _riskFreeValueReceiver
    );
    event ClearStuckBalance(
        uint256 indexed amount,
        address indexed receiver,
        uint256 indexed time
    );
    event RescueToken(
        address indexed tokenAddress,
        address indexed sender,
        uint256 indexed tokens,
        uint256 time
    );
    event SetAutoRebaseEnabled(bool indexed value, uint256 indexed time);
    event DisableLaunchFee(uint256 indexed time);
    event SetTaxBracketEnabled(bool indexed value, uint256 indexed time);
    event SetNextRebase(uint256 indexed value, uint256 indexed time);
    event SetTransferFeeEnabled(bool indexed value, uint256 indexed time);
    event SetSwapBackEnabled(bool indexed value);
    event LogRebase(uint256 indexed epoch, uint256 totalSupply);
    event LogManualRebase(uint256 circulatingSupply, uint256 timeStamp);
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event SetFeeExempt(address indexed addy, bool indexed value);
    event SetRouter(address indexed routerAddress, uint256 indexed time);
    event SetPair(address indexed pairAddress, uint256 indexed time);
}
