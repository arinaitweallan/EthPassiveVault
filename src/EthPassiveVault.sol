// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IAaveOracle} from "src/interfaces/IAaveOracle.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Escrow} from "src/Escrow.sol";
import {IEscrow} from "src/interfaces/IEscrow.sol";

/// @author Arinaitwe Allan
/// @notice EthPassiveVault: User deposits ETH, withdraws 2% of the balance worth at the time of deposit every month
/// @dev Protected to only owner

contract EthPassiveVault is ERC20, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error CantRenounceContract();
    error EtherMismatch();
    error InvalidAmount();
    error NotAvailable();
    error ZeroAddress();
    error OracleError();
    error TransferFailed();
    error InvalidEntry();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event Deposit(address indexed account, uint256 indexed amount);
    event Withdraw(address indexed account, uint256 indexed amount);
    event Transfer(address indexed token, uint256 indexed amount);
    event DelayUpdated(uint256 indexed newDelay);

    /*//////////////////////////////////////////////////////////////
                              AAVE ORACLE
    //////////////////////////////////////////////////////////////*/
    // Aave V3 @audit: need to be verified
    IAaveOracle immutable aaveOracle; // 0xD63f7658C66B2934Bd234D79D06aEF5290734B30

    IEscrow public escrow;

    /*//////////////////////////////////////////////////////////////
                           STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 public deployed;
    uint256 public withdrawTimer;
    uint256 public catchUpTimer;
    uint256 public emergencyTimer;
    uint256 public emergencyDelay;

    // scaled to aave scale of 1e8
    uint256 public monthlyPayInUsdE8;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint256 internal constant WITHDRAW_DELAY = 30 days;
    uint256 internal constant PAY_FACTOR = 200; // 2%
    uint256 internal constant SCALE = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MIN_DEPOSIT = 0.03 ether; // $90 at $3000 ETH price
    uint256 internal constant EMERGENCY_CUT = 2_000; // 20%
    uint256 internal constant MIN_EMERGENCY_DELAY = 14 days;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(address _aaveOracle) ERC20("ETH Vault Shares", "EVS") Ownable(_msgSender()) {
        aaveOracle = IAaveOracle(_aaveOracle);
        withdrawTimer = block.timestamp;
        emergencyTimer = block.timestamp;
        emergencyDelay = MIN_EMERGENCY_DELAY;

        // deploy escrow contract with vault and token as address(this)
        escrow = IEscrow(address(new Escrow(address(this), address(this))));
    }

    /*//////////////////////////////////////////////////////////////
                                 PUBLIC
    //////////////////////////////////////////////////////////////*/
    /// @dev overrie ownable2step to revert renouncing ownership
    function renounceOwnership() public pure override {
        revert CantRenounceContract();
    }

    /// @dev override ownable2step to transfer shares to escrow contract
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        _transferSharesToEscrow();
        super.transferOwnership(newOwner);
    }

    /// @dev override ownable2step to transfer shares from escrow contract to new owner
    function acceptOwnership() public virtual override {
        super.acceptOwnership();
        // after accepting ownership
        _transferSharesFromEscrowToNewOwner();
    }

    // get oracle price to fecth the price of eth
    // returned in a scale of 8 decimals
    // @test: need to test in forked environment

    /// @dev function to fetch eth price from aave oracle
    function getEthPrice() public view returns (uint256 price) {
        // q will address(0) fetch the price of eth
        price = aaveOracle.getAssetPrice(address(0));
        if (price == 0) revert OracleError();
    }

    /*//////////////////////////////////////////////////////////////
                                EXTERNAL
    //////////////////////////////////////////////////////////////*/
    /// @notice function to deposit ether into the contract
    /// @notice mints shares equal to amount deposited
    /// @param amount ether amount to deposit
    function deposit(uint256 amount) external payable nonReentrant {
        require(amount != 0, InvalidAmount());
        require(amount == msg.value, EtherMismatch());
        require(amount >= MIN_DEPOSIT, InvalidAmount());

        _calculateMonthlyPayOut(amount);

        deployed += amount;
        address _owner = owner();
        _mint(_owner, amount);
        address sender = _msgSender();
        emit Deposit(sender, amount);
    }

    /// @dev function to let the owner withdraw monthly ether payout
    function withdraw() external nonReentrant onlyOwner {
        uint256 timerPlusDelay = withdrawTimer + WITHDRAW_DELAY;
        uint256 timeStamp = block.timestamp;

        // check if enough time has passed
        bool available = timeStamp > timerPlusDelay;
        require(available, NotAvailable());

        _catchUpTime(timeStamp, timerPlusDelay);
        withdrawTimer = block.timestamp;
        _processWithdraw();
    }

    // q on transferring ownership, should we transfer the shares as well?
    // override acceptOwnership

    // transferOwnership -> pending owner, OZ function cant transfer ownership to address(0)
    // acceptOwnership -> new owner
    // transfer shares balance to escrow, on accepting ownership, transfer shares to new owner

    /// @dev function to withdraw ether for the delays in the claims
    /// @notice this is because the monthly claims are not automatic
    /// @notice when there is more than one month in claim, the user
    /// has to call this function for every claim
    function withdrawCatchUp() external nonReentrant onlyOwner {
        bool available = catchUpTimer > WITHDRAW_DELAY;
        require(available, NotAvailable());

        catchUpTimer -= WITHDRAW_DELAY;
        _processWithdraw();
    }

    /// @dev this function withdraws any ERC20 tokens in the contract
    /// @param token ERC20 token to transfer
    /// @param to address to transfer token to
    /// @param amount amount to transfer
    function sweepErcToken(address token, address to, uint256 amount) external nonReentrant onlyOwner {
        require(token != address(0), ZeroAddress());
        require(amount != 0, InvalidAmount());

        uint256 balance = IERC20(token).balanceOf(address(this));

        // protect underflow
        if (amount > balance) {
            amount = balance;
        }

        IERC20(token).safeTransfer(to, amount);
        emit Transfer(to, amount);
    }

    /// @dev function to withdraw unbacked ether in the contract
    function sweepUnbackedEth() external nonReentrant onlyOwner {
        // preserve deployed capital
        uint256 _balance = _contractBalance();
        uint256 _deployed = deployed;

        // unbacked is true if balance > deployed
        require(_balance > _deployed, NotAvailable());

        uint256 toTake = _balance - _deployed;
        _transferEther(toTake);
    }

    /*//////////////////////////////////////////////////////////////
                                PRIVATE
    //////////////////////////////////////////////////////////////*/
    // internal helpers for transfering shares when transfering ownership
    function _transferSharesToEscrow() private {
        address _owner = owner();
        uint256 _shares = IERC20(address(this)).balanceOf(_owner);
        // transfer the share balance of owner to escrow contract
        _transfer(_owner, address(escrow), _shares);
    }

    function _transferSharesFromEscrowToNewOwner() private {
        address _from = address(escrow);
        address _to = owner();
        uint256 _shares = IERC20(address(this)).balanceOf(_from);
        escrow.transferShares(_to, _shares);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/
    /// @notice calculates the constant monthly pay in usd based the
    /// deployed amount
    /// @notice stores the 2% of deployed amount at the deployment price
    /// and adds to the current `monthlyPayInUsdE8`
    function _calculateMonthlyPayOut(uint256 amount) internal {
        uint256 aavePrice = getEthPrice(); // scaled to 1e8
        // this is below the aave oracle scale but the multiplication
        // before division in calculating `amountToPay` which restores
        uint256 payout = amount * aavePrice * PAY_FACTOR / SCALE / WAD;

        monthlyPayInUsdE8 += payout;
    }

    /// @dev record catch up time for the time missed after exactly 30 days
    /// @param timeStamp current block.timestamp
    /// @param timerPlusDelay last withraw timer plus the 30 days delay
    function _catchUpTime(uint256 timeStamp, uint256 timerPlusDelay) internal {
        uint256 catchUp = timeStamp - timerPlusDelay;
        catchUpTimer += catchUp;
    }

    /// @dev internal function transfer ether to msg.sender
    function _processWithdraw() internal {
        uint256 _monthlyPayInUsdScaledToE8 = monthlyPayInUsdE8;
        uint256 _price = getEthPrice();
        // this is to ensure we withdraw 2% of initial deployment at initial price
        // amount to pay decreases when price goes up and increases when price goes down
        uint256 amountToPay = _monthlyPayInUsdScaledToE8 * WAD / _price;
        _updateStateAndWithdraw(amountToPay);
    }

    /// @dev internal state update, burn shares an withdraw
    /// @param amount ether amount to withdraw
    function _updateStateAndWithdraw(uint256 amount) internal {
        address sender = _msgSender();
        deployed -= amount;
        _burn(sender, amount);
        _transferEther(amount);
    }

    /// @dev transfer ether
    /// @param amount ether amount to transfer
    function _transferEther(uint256 amount) internal {
        address sender = _msgSender();
        (bool success,) = payable(sender).call{value: amount}("");
        require(success, TransferFailed());
        emit Withdraw(sender, amount);
    }

    /// @dev fetch contract ether balance
    function _contractBalance() internal view returns (uint256) {
        return address(this).balance;
    }

    /// @dev update monthly payout on emergency withdraw
    /// @param amount emergency amount to withdraw
    /// @param available max amount available to withdraw
    function _updateMonthlyPayout(uint256 amount, uint256 available) internal {
        uint256 _deployed = deployed;
        uint256 currentMonthlyPayout = monthlyPayInUsdE8;
        uint256 emergencyWithdrawCut;

        if (amount == available) {
            emergencyWithdrawCut = currentMonthlyPayout * EMERGENCY_CUT / SCALE;
        } else {
            uint256 factor = amount * SCALE / _deployed;
            emergencyWithdrawCut = currentMonthlyPayout * factor / SCALE;
        }

        monthlyPayInUsdE8 -= emergencyWithdrawCut;
    }

    /*//////////////////////////////////////////////////////////////
                               EMERGENCY
    //////////////////////////////////////////////////////////////*/
    /// @dev function to withdraw ether in case of an emergency
    function emergencyWithraw(uint256 amount) external nonReentrant onlyOwner {
        bool allowed = block.timestamp > emergencyTimer + emergencyDelay;
        require(allowed, NotAvailable());

        uint256 _balance = _contractBalance();
        require(_balance > 0, NotAvailable());

        uint256 _available = _balance * EMERGENCY_CUT / SCALE; // min = 0.03 * 1e18 * 2_000 / 10_000 = 6000000000000000

        // cap amount to available
        if (amount > _available) {
            amount = _available;
        }

        emergencyTimer = block.timestamp;
        _updateMonthlyPayout(amount, _available);
        _updateStateAndWithdraw(amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 UPDATE
    //////////////////////////////////////////////////////////////*/
    /// @notice function to update emergency delay
    function updateEmergencyDelay(uint256 _delay) external onlyOwner {
        require(_delay >= MIN_EMERGENCY_DELAY, InvalidEntry());
        emergencyDelay = _delay;
        emit DelayUpdated(_delay);
    }

    /// @dev fallback function to receive ether
    receive() external payable {}
}

