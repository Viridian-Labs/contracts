// 1:1 with Hardhat test
pragma solidity 0.8.13;

import "../test/BaseTest.sol";

contract ViriVotingTest is BaseTest {
    VotingEscrow escrow;
    GaugeFactory gaugeFactory;
    BribeFactory bribeFactory;
    Voter voter;
    RewardsDistributor distributor;
    Minter minter;
    TestOwner team;

    function setUp() public {
        vm.warp(block.timestamp + 1 days); // put some initial time in

        deployOwners();
        deployCoins();
        mintStables();
        uint256[] memory amountsViri = new uint256[](2);
        amountsViri[0] = 1e25;
        amountsViri[1] = 1e25;
        mintViri(owners, amountsViri);
        team = new TestOwner();
        VeArtProxy artProxy = new VeArtProxy();
        escrow = new VotingEscrow(address(VIRI), address(artProxy));
        factory = new PairFactory();
        router = new Router(address(factory), address(owner));
        gaugeFactory = new GaugeFactory();
        bribeFactory = new BribeFactory();
        voter = new Voter(
            address(escrow),
            address(factory),
            address(gaugeFactory),
            address(bribeFactory)
        );

        address[] memory tokens = new address[](2);
        tokens[0] = address(FRAX);
        tokens[1] = address(VIRI);
        voter.initialize(tokens, address(owner));
        VIRI.approve(address(escrow), TOKEN_1);
        escrow.create_lock(TOKEN_1, 1 * 365 * 86400);
        distributor = new RewardsDistributor(address(escrow));
        escrow.setVoter(address(voter));

        minter = new Minter(
            address(voter),
            address(escrow),
            address(distributor)
        );
        distributor.setDepositor(address(minter));
        VIRI.setMinter(address(minter));

        VIRI.approve(address(router), TOKEN_1);
        FRAX.approve(address(router), TOKEN_1);
        router.addLiquidity(
            address(FRAX),
            address(VIRI),
            false,
            TOKEN_1,
            TOKEN_1,
            0,
            0,
            address(owner),
            block.timestamp
        );

        address pair = router.pairFor(address(FRAX), address(VIRI), false);

        VIRI.approve(address(voter), 5 * TOKEN_100K);
        voter.createGauge(pair);
        vm.roll(block.number + 1); // fwd 1 block because escrow.balanceOfNFT() returns 0 in same block
        assertGt(escrow.balanceOfNFT(1), 995063075414519385);
        assertEq(VIRI.balanceOf(address(escrow)), TOKEN_1);

        address[] memory pools = new address[](1);
        pools[0] = pair;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 5000;
        voter.vote(1, pools, weights);

        address[] memory claimants = new address[](1);
        claimants[0] = address(owner);
        uint256[] memory amountsToMint = new uint256[](1);
        amountsToMint[0] = TOKEN_1M;
        minter.initialize(claimants, amountsToMint, 1_838_000 * 1e18);
        assertEq(escrow.ownerOf(2), address(owner));
        assertEq(escrow.ownerOf(3), address(0));
        vm.roll(block.number + 1);
        assertEq(VIRI.balanceOf(address(minter)), 838_000 * 1e18);

        uint256 before = VIRI.balanceOf(address(owner));
        minter.update_period(); // initial period week 1
        uint256 after_ = VIRI.balanceOf(address(owner));
        assertEq(minter.weekly(), 100_000 * 1e18);
        assertEq(after_ - before, 0);
        vm.warp(block.timestamp + 86400 * 1);
        vm.roll(block.number + 1);
        before = VIRI.balanceOf(address(owner));
        minter.update_period(); // initial period week 2
        after_ = VIRI.balanceOf(address(owner));
        assertLt(minter.weekly(), 100_000 * 1e18);  // <15M for week shift
    }

    // Note: _vote and _reset are not included in one-vote-per-epoch
    // Only vote() and reset() should be constrained as they must be called by the owner
    // poke() can be called by anyone anytime to "refresh" an outdated vote state

    function testCannotChangeVoteOrResetInSameEpoch() public {
        // vote
        vm.warp(block.timestamp + 1 days);
        address[] memory pools = new address[](1);
        pools[0] = address(pair);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 5000;
        voter.vote(1, pools, weights);

        // fwd half epoch
        vm.warp(block.timestamp + 1 days / 2);

        // try voting again and fail
        pools[0] = address(pair2);
        vm.expectRevert(abi.encodePacked("TOKEN_ALREADY_VOTED_THIS_EPOCH"));
        voter.vote(1, pools, weights);

        // try resetting and fail
        vm.expectRevert(abi.encodePacked("TOKEN_ALREADY_VOTED_THIS_EPOCH"));
        voter.reset(1);
    }

    function testCanChangeVoteOrResetInNextEpoch() public {
        // vote
        vm.warp(block.timestamp + 1 days);
        address[] memory pools = new address[](1);
        pools[0] = address(pair);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 5000;

        voter.vote(1, pools, weights);

        // fwd whole epoch
        vm.warp(block.timestamp + 1 days);

        // try voting again and fail
        pools[0] = address(pair2);
        voter.vote(1, pools, weights);

        // fwd whole epoch
        vm.warp(block.timestamp + 1 days);

        voter.reset(1);
    }
}
