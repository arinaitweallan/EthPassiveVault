// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {EthPassiveVault} from "src/EthPassiveVault.sol";
import {AaveOracleMock} from "test/mocks/AaveOracleMock.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Reenter} from "test/helpers/Reenter.sol";
import {IEscrow} from "src/interfaces/IEscrow.sol";
import {Escrow} from "src/Escrow.sol";
import {MockToken} from "test/mocks/MockToken.sol";

contract VaultTest is Test {
    EthPassiveVault vault;
    AaveOracleMock oracle;
    MockToken token;

    address _owner = address(0x7fff);
    address lisa = address(0x123);
    address gina = address(0x124);

    uint256 year = 365 days;

    // events
    event Deposit(address indexed account, uint256 indexed amount);

    function setUp() external {
        // warp the timestamp almost to the current time
        vm.warp(block.timestamp + (year * 56));

        // deploy mock oracle and token
        oracle = new AaveOracleMock();
        token = new MockToken();

        // deploy as _owner
        vm.prank(_owner);
        vault = new EthPassiveVault(address(oracle));
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    function testConstructor() public view {
        uint256 timestamp = block.timestamp;
        uint256 emergencyTimer = 14 days;

        assertEq(vault.withdrawTimer(), timestamp);
        assertEq(vault.emergencyTimer(), timestamp);
        assertEq(vault.emergencyDelay(), emergencyTimer);

        // escrow
        IEscrow _escrow = vault.escrow();
        // Route: IEscrow -> address -> Escrow
        assertEq(address(Escrow(address(_escrow)).token()), address(vault));
        assertEq(address(Escrow(address(_escrow)).vault()), address(vault));
    }

    /*//////////////////////////////////////////////////////////////
                            RENOUNCE REVERT
    //////////////////////////////////////////////////////////////*/
    function testRenounceReverts(address caller) public {
        _notZeroAddress(caller);

        vm.prank(caller);
        vm.expectRevert(EthPassiveVault.CantRenounceContract.selector);
        vault.renounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/
    function testEtherMismatchRevertsDeposit(address user) public {
        _notZeroAddress(user);

        uint256 amount = 1000 ether;
        _deal(user, amount);

        vm.prank(user);
        vm.expectRevert(EthPassiveVault.EtherMismatch.selector);
        vault.deposit{value: amount}(amount - 1);
    }

    function testInvalidAmountDeposit(address user) public {
        _notZeroAddress(user);

        uint256 amount = 1 ether;
        _deal(user, amount);

        vm.prank(user);
        vm.expectRevert(EthPassiveVault.InvalidAmount.selector);
        vault.deposit{value: 0}(0);
    }

    function testBelowMinDeposit(address user, uint256 amount) public {
        uint256 min = 0.03 ether;

        vm.assume(amount > 0 && amount < min);
        _notZeroAddress(user);
        _deal(user, amount);

        vm.prank(user);
        vm.expectRevert(EthPassiveVault.InvalidAmount.selector);
        vault.deposit{value: amount}(amount);
    }

    function testCalculateMonthlyPayout(address user) public {
        uint256 amount = 1 ether;
        _notZeroAddress(user);
        _deal(user, amount);

        // assert payout == 0 before deposit
        assertEq(vault.monthlyPayInUsdE8(), 0);

        vm.prank(user);
        vault.deposit{value: amount}(amount);

        // eth price = 2000e8
        // payout = amount * aavePrice * PAY_FACTOR / SCALE / WAD
        // payout = 1e18 * 2000e8 * 200 / 10_000 / 1e18 = 4_000_000_000

        uint256 _payout = vault.monthlyPayInUsdE8();
        console2.log("Monthly pay in USD e8: ", _payout);

        // assert payout
        assertEq(4_000_000_000, _payout);
    }

    function testFuzzCalculateMonthlyPayout(address user, uint256 _amount) public {
        uint256 amount = _boundDepositAmount(_amount);
        _notZeroAddress(user);
        _deal(user, amount);

        // deposit
        vm.prank(user);
        vault.deposit{value: amount}(amount);

        // eth price = 2000e8
        // payout = amount * aavePrice * PAY_FACTOR / SCALE / WAD
        uint256 payout = amount * 2000e8 * 200 / 10_000 / 1e18;

        uint256 _payout = vault.monthlyPayInUsdE8();
        console2.log("Monthly pay in USD e8 contract value: ", _payout);
        console2.log("Monthly pay in USD e8 test calculation: ", payout);

        // assert payout
        assertEq(payout, _payout);
    }

    function testDeployedUpdatedDeposit(address user, uint256 _amount) public {
        uint256 amount = _boundDepositAmount(_amount);
        _notZeroAddress(user);
        _deal(user, amount);

        // assert deployed before deposit == 0
        assertEq(vault.deployed(), 0);

        // deposit
        vm.prank(user);
        vault.deposit{value: amount}(amount);

        // deployed state updated
        uint256 _deployed = vault.deployed();

        // assert
        assertEq(_deployed, amount);
    }

    function testMintSharesToUser(address user, uint256 _amount) public {
        uint256 amount = _boundDepositAmount(_amount);
        _notZeroAddress(user);
        _deal(user, amount);

        // assert total supply == 0 before deposit
        uint256 _supply = IERC20(vault).totalSupply();
        assertEq(_supply, 0);

        // deposit
        vm.prank(user);
        vault.deposit{value: amount}(amount);

        // shares minted == amount
        uint256 supply_ = IERC20(vault).totalSupply();
        assertEq(supply_, amount);
        // _owner has `amount` shares
        uint256 shares_ = IERC20(vault).balanceOf(_owner);
        assertEq(shares_, amount);

        // assert msg.sender (if not owner) shares balance is zero
        assertEq(IERC20(vault).balanceOf(user), 0);
    }

    function testEmitEventDeposit(address user, uint256 _amount) public {
        uint256 amount = _boundDepositAmount(_amount);
        _notZeroAddress(user);
        _deal(user, amount);

        // Our event has 2 indexed topics (account, amount).
        vm.expectEmit(true, true, false, false);
        emit Deposit(user, amount);

        // deposit
        vm.prank(user);
        vault.deposit{value: amount}(amount);
    }

    // happy path deposit
    function test_deposit(address user, uint256 _amount) public {
        uint256 amount = _boundDepositAmount(_amount);
        _notZeroAddress(user);
        _deal(user, amount);

        // deposit
        vm.prank(user);
        vault.deposit{value: amount}(amount);
    }

    /*//////////////////////////////////////////////////////////////
                           TRANSFER OWNERSHIP
    //////////////////////////////////////////////////////////////*/
    function testNonOwnerTransferOwnershipReverts(address _notOwner) public {
        vm.assume(_notOwner != _owner);

        vm.prank(_notOwner);
        vm.expectRevert();
        vault.transferOwnership(_notOwner);
    }

    function testNonPendingOwnerAcceptOwnershipReverts(address _notPendingowner) public {
        vm.prank(_owner);
        address _pendingOwner = address(0x2FF);
        vault.transferOwnership(_pendingOwner);

        vm.assume(_notPendingowner != _pendingOwner);

        vm.prank(_notPendingowner);
        vm.expectRevert();
        vault.acceptOwnership();
    }

    function testTransferOwnership(address user) public {
        // user deposits
        uint256 amount = 1 ether;
        _deposit(user, amount);

        uint256 _shares = vault.balanceOf(_owner);
        assertGe(_shares, 0);
        assertEq(_shares, amount);

        // transfer ownership to new owner
        address owner_ = address(0x5c);

        vm.prank(_owner);
        vault.transferOwnership(owner_);

        // before accepting ownership, assert escrow holds the shares
        address _escrow = address(vault.escrow());
        uint256 escrowShares = vault.balanceOf(_escrow);
        assertEq(escrowShares, amount);

        // accept ownership
        vm.prank(owner_);
        vault.acceptOwnership();

        // after acceptance, check new owner has shares
        uint256 newOwnerShares = vault.balanceOf(owner_);
        assertEq(newOwnerShares, amount);
    }

    function testEscrowNonVaultTransfer() public {
        IEscrow _escrow = vault.escrow();

        vm.prank(address(0xFF));
        vm.expectRevert(IEscrow.NotAuthorized.selector);
        _escrow.transferShares(address(0xFF), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/
    function testNoneOwnerReverts(address user, uint256 amount) public {
        vm.assume(user != _owner);
        // user deposits
        _deposit(user, amount);

        // non owner tries withdraw
        vm.prank(user);
        vm.expectRevert(); // error from `Ownable`
        vault.withdraw();
    }

    function testReenterancyReverts(address user, uint256 amount) public {
        // user deposits
        _deposit(user, amount);

        Reenter attack = new Reenter(payable(address(vault)));

        // first transfer ownership to reenter
        vm.startPrank(_owner);
        bool ok = vault.transfer(address(attack), vault.balanceOf(_owner));
        require(ok);
        vault.transferOwnership(address(attack));
        vm.stopPrank();

        vm.prank(address(attack));
        vault.acceptOwnership();

        // warp the time
        vm.warp(block.timestamp + 31 days);

        // reenter tries withdraw
        vm.prank(address(attack));
        vm.expectRevert(); // error from `ReentrancyGuard`
        vault.withdraw();
    }

    function testBeforeWithdrawDelayReverts(address user, uint256 _days) public {
        vm.assume(_days <= 30 days);
        uint256 amount = 100 ether;
        _deposit(user, amount);

        vm.warp(block.timestamp + _days);

        // withdraw before 30 days
        vm.prank(_owner);
        vm.expectRevert(EthPassiveVault.NotAvailable.selector);
        vault.withdraw();
    }

    function testRecordCatchupTimer(address user) public {
        uint256 amount = 100 ether;
        _deposit(user, amount);

        uint256 min = 30 days;
        uint256 _days = min + 1;
        uint256 _then = block.timestamp;
        vm.warp(block.timestamp + _days);

        uint256 _catchup = _days - min;
        // assert catchup timer before withdraw is zero
        assertEq(vault.catchUpTimer(), 0);

        // withdraw after 30 days
        vm.prank(_owner);
        vault.withdraw();

        // assert catchup timer after withdraw is _catchup
        assertEq(vault.catchUpTimer(), _catchup);

        // assert withdraw timer == block.timestamp
        uint256 _now = block.timestamp;
        assertEq(vault.withdrawTimer(), block.timestamp);
        assertGe(_now, _then);
    }

    function testUpdatedDeployedAndBurnShares(address user) public {
        uint256 amount = 100 ether;
        _withdraw(user, amount);

        uint256 _updatedDeployed = vault.deployed();
        uint256 payout = vault.monthlyPayInUsdE8() * 1e18 / 2000e8;
        assertEq(_updatedDeployed, (amount - payout));

        // shares burned because its 1:1 basis
        uint256 _updatedShares = vault.totalSupply();
        assertEq(_updatedShares, (amount - payout));

        // @invariant: shares should always equal to deployed capital
        // @invariant: contract balance >= deployed capital / shares minted
        assertEq(_updatedDeployed, _updatedShares);
    }

    function testOwnerReceivesEther(address user) public {
        uint256 amount = 100 ether;
        _withdraw(user, amount);

        uint256 _updatedBalance = address(vault).balance;
        uint256 payout = vault.monthlyPayInUsdE8() * 1e18 / 2000e8;
        assertEq(_updatedBalance, (amount - payout));

        // shares burned because its 1:1 basis
        uint256 _updatedShares = vault.totalSupply();
        assertEq(_updatedShares, (amount - payout));

        assertGe(_updatedBalance, _updatedShares);

        // assert payout == new ether balance of _owner
        uint256 _ownerBalance = address(_owner).balance;
        assertEq(_ownerBalance, payout);
    }

    function testPrice2xUpWithdraw(address user) public {
        uint256 amount = 100 ether;
        _deposit(user, amount);

        uint256 min = 30 days;
        uint256 _days = min + 1e3;
        vm.warp(block.timestamp + _days);

        // price increases
        oracle.setPrice(4000);

        // withdraw after 30 days
        vm.prank(_owner);
        vault.withdraw();

        uint256 _updatedBalance = address(vault).balance;
        uint256 payout = vault.monthlyPayInUsdE8() * 1e18 / 4000e8;
        // assert payout decrease by 50%
        assertEq(_updatedBalance, (amount - payout));
    }

    function testPrice50PercentDownWithdraw(address user) public {
        uint256 amount = 100 ether;
        _deposit(user, amount);

        uint256 min = 30 days;
        uint256 _days = min + 1e3;
        vm.warp(block.timestamp + _days);

        // price increases
        oracle.setPrice(1000);

        // withdraw after 30 days
        vm.prank(_owner);
        vault.withdraw();

        uint256 _updatedBalance = address(vault).balance;
        uint256 payout = vault.monthlyPayInUsdE8() * 1e18 / 1000e8;
        // assert payout increases by 100%
        // to match the constant USD value
        assertEq(_updatedBalance, (amount - payout));
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAW CATCHUP
    //////////////////////////////////////////////////////////////*/
    function testNotAvailableCatchUp(address user) public {
        uint256 amount = 100 ether;
        uint256 time = 21 days;

        _withdrawAddCatchUp(user, amount, time);

        // catchup withdraw before catchup timer full
        vm.prank(_owner);
        vm.expectRevert(EthPassiveVault.NotAvailable.selector);
        vault.withdrawCatchUp();
    }

    function testCatchupWithdrawAndTimerUpdate(address user) public {
        uint256 amount = 100 ether;
        uint256 time = 31 days;

        _withdrawAddCatchUp(user, amount, time);

        // assert catchup timer is up 31 days
        assertEq(vault.catchUpTimer(), time);

        // catchup withdraw after catchup timer full
        vm.prank(_owner);
        vault.withdrawCatchUp();

        // assert catchup timer reduces by 30 days due to withdraw
        uint256 _time = time - 30 days;
        assertEq(vault.catchUpTimer(), _time);
    }

    function testMultipleWithdrawDelaysFillUpCatchUpTimerForOneWithdraw(address user) public {
        uint256 amount = 100 ether;
        _deposit(user, amount);

        _withdrawAfterDeposit(36 days); // +6
        _withdrawAfterDeposit(40 days); // +10
        _withdrawAfterDeposit(37 days); // +7
        _withdrawAfterDeposit(39 days); // +9 = 32 days total
        // catchup withdraw should be ready

        // first check the catchup timer
        uint256 _catchupTimer = vault.catchUpTimer();
        uint256 _thirtyDays = 30 days;
        assertGe(_catchupTimer, _thirtyDays);

        // withdraw catchup
        vm.prank(_owner);
        vault.withdrawCatchUp();

        // only two days on the timer now
        assertLe(vault.catchUpTimer(), _thirtyDays);
    }

    /*//////////////////////////////////////////////////////////////
                               SWEEP ERC
    //////////////////////////////////////////////////////////////*/
    function testNonOwnerZeroAmountAddressSweepReverts() public {
        uint256 amount = 10_000_000e18;
        _mintErcTokensToVault(amount);

        // non owner tries to sweep
        vm.prank(address(0x5bc));
        vm.expectRevert();
        vault.sweepErcToken(address(token), address(0x5bc), amount);

        // owner tries sweep amount zero
        vm.prank(_owner);
        vm.expectRevert(EthPassiveVault.InvalidAmount.selector);
        vault.sweepErcToken(address(token), _owner, 0);

        // owner tries sweep token address(0)
        vm.prank(_owner);
        vm.expectRevert(EthPassiveVault.ZeroAddress.selector);
        vault.sweepErcToken(address(0), address(0), amount);
    }

    function testAmountMoreThanBalanceClampsToBalance() public {
        uint256 amount = 10_000_000e18;
        _mintErcTokensToVault(amount);

        // owner sweeps
        vm.prank(_owner);
        vault.sweepErcToken(address(token), _owner, type(uint256).max);

        assertEq(IERC20(token).balanceOf(address(_owner)), amount);
    }

    /*//////////////////////////////////////////////////////////////
                           SWEEP UNBACKED ETH
    //////////////////////////////////////////////////////////////*/
    function testEthNonOwnerSweeps() public {
        vm.prank(address(0x5d));
        vm.expectRevert();
        vault.sweepUnbackedEth();
    }

    function testCantSweepDeployed(address user) public {
        uint256 _amount = 1 ether;
        _deposit(user, _amount);

        vm.prank(_owner);
        vm.expectRevert(EthPassiveVault.NotAvailable.selector);
        vault.sweepUnbackedEth();
    }

    // function testUnbackedSweep(address user) public {
    //     // deal unbacked ether to vault
    //     vm.deal(address(vault), 1e14);

    //     uint256 _amount = 1 ether;
    //     _deposit(user, _amount);

    //     // assert deployed == 1 ether
    //     assertEq(vault.deployed(), _amount);

    //     console2.log("Vault ether balance: ", address(vault).balance);

    //     vm.prank(_owner);
    //     vault.sweepUnbackedEth();

    //     // assert deployed == 1 ether even after sweeping unbacked ether
    //     assertEq(vault.deployed(), _amount);
    // }

    /*//////////////////////////////////////////////////////////////
                                 UPDATE
    //////////////////////////////////////////////////////////////*/
    function testUpdateNoneOwnerReverts() public {
        uint256 _delay = 90 days;
        vm.prank(address(0x4b));
        vm.expectRevert();
        vault.updateEmergencyDelay(_delay);
    }

    function testDelayBelowMinReverts(uint256 _delay) public {
        vm.assume(_delay < 14 days);

        vm.prank(_owner);
        vm.expectRevert(EthPassiveVault.InvalidEntry.selector);
        vault.updateEmergencyDelay(_delay);
    }

    function testNewDelaySet(uint256 _delay) public {
        vm.assume(_delay >= 14 days);

        vm.prank(_owner);
        vault.updateEmergencyDelay(_delay);

        assertEq(vault.emergencyDelay(), _delay);
    }

    /*//////////////////////////////////////////////////////////////
                               EMERGENCY
    //////////////////////////////////////////////////////////////*/
    function testEmergencyNonOwnerReverts() public {
        vm.prank(address(0x4b));
        vm.expectRevert();
        vault.emergencyWithraw(type(uint8).max);
    }

    function testIsNotAvailable() public {
        vm.prank(_owner);
        vm.expectRevert(EthPassiveVault.NotAvailable.selector);
        vault.emergencyWithraw(type(uint8).max);
    }

    function testAvailableTimerNoFundsReverts() public {
        vm.warp(block.timestamp + 20 days);

        vm.prank(_owner);
        vm.expectRevert(EthPassiveVault.NotAvailable.selector);
        vault.emergencyWithraw(type(uint8).max);
    }

    function testClampAmountToAvailable(address user) public {
        uint256 amount = 1000 ether;
        _deposit(user, amount);

        vm.warp(block.timestamp + 20 days);

        vm.prank(_owner);
        vault.emergencyWithraw(type(uint160).max);
    }

    function testAmountLessThanAvailable(address user) public {
        uint256 amount = 1000 ether;
        _deposit(user, amount);

        uint256 _updatedPayout = vault.monthlyPayInUsdE8();
        console2.log("Initial monthly payout: ", _updatedPayout);

        vm.warp(block.timestamp + 20 days);

        vm.prank(_owner);
        vault.emergencyWithraw(1e19);

        uint256 updatedPayout = vault.monthlyPayInUsdE8();
        console2.log("Updated monthly payout: ", updatedPayout);
    }

    /*//////////////////////////////////////////////////////////////
                                 ORACLE
    //////////////////////////////////////////////////////////////*/
    function testGetEthPrice() public view {
        uint price = vault.getEthPrice();
        assertGe(price, 0);
    }

    function testZeroPriceReverts() public {
        oracle.setPrice(0);
        vm.expectRevert(EthPassiveVault.OracleError.selector);
        vault.getEthPrice();
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/
    function _mintErcTokensToVault(uint256 amount) internal {
        // mint mock tokens to vault
        token.mint(address(vault), amount);
        assertEq(IERC20(token).balanceOf(address(vault)), amount);
    }

    function _withdrawAfterDeposit(uint256 time) internal {
        // withdraw after 30 days
        vm.warp(block.timestamp + time);
        uint256 min = 35 days;
        require(time > min, "less than 35 days");

        vm.prank(_owner);
        vault.withdraw();
    }

    function _withdrawAddCatchUp(address user, uint256 amount, uint256 time) internal {
        _deposit(user, amount);

        uint256 min = 30 days;
        uint256 _days = min + time;
        require(time > 0, "failed");
        vm.warp(block.timestamp + _days);

        // withdraw after 30 days
        vm.prank(_owner);
        vault.withdraw();
    }

    function _withdraw(address user, uint256 amount) internal {
        _deposit(user, amount);

        uint256 min = 30 days;
        uint256 _days = min + 1e3;
        vm.warp(block.timestamp + _days);

        // withdraw after 30 days
        vm.prank(_owner);
        vault.withdraw();
    }

    function _deposit(address user, uint256 _amount) internal {
        uint256 amount = _boundDepositAmount(_amount);
        _notZeroAddress(user);
        _deal(user, amount);

        // deposit
        vm.prank(user);
        vault.deposit{value: amount}(amount);
    }

    function _boundDepositAmount(uint256 amount) internal pure returns (uint256 _amount) {
        uint256 min = 0.03 ether;
        uint256 max = 1_000_000 ether;

        amount = bound(amount, min, max);
        _amount = amount;
    }

    function _notZeroAddress(address caller) internal pure {
        vm.assume(caller != address(0));
    }

    function _deal(address user, uint256 amount) internal {
        vm.deal(user, amount);
    }
}
