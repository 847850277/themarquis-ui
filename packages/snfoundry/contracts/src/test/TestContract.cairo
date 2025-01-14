use contracts::IMarquisCore::{
    Constants, IMarquisCoreDispatcher, IMarquisCoreDispatcherTrait, SupportedToken,
};
use contracts::interfaces::ILudo::{
    ILudoDispatcher, ILudoDispatcherTrait, LudoMove, SessionUserStatus,
};
use contracts::interfaces::IMarquisGame::{
    IMarquisGameDispatcher, IMarquisGameDispatcherTrait, VerifiableRandomNumber,
};
use core::num::traits::Zero;
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use openzeppelin_upgrades::interface::{IUpgradeableDispatcher, IUpgradeableDispatcherTrait};
use openzeppelin_upgrades::upgradeable::UpgradeableComponent;
use openzeppelin_utils::serde::SerializedAppend;
use snforge_std::{
    CheatSpan, ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait, EventSpyTrait,
    EventsFilterTrait, cheat_caller_address, cheatcodes::events::Event, declare, spy_events,
};
use starknet::{ContractAddress, EthAddress, contract_address_const};

// Real contract addresses deployed on Sepolia
fn OWNER() -> ContractAddress {
    contract_address_const::<0x02dA5254690b46B9C4059C25366D1778839BE63C142d899F0306fd5c312A5918>()
}

fn PLAYER_0() -> ContractAddress {
    contract_address_const::<0x01528adf08bf1f8895aea018155fd8ad1cfc2b4935c680b948bc87f425eafd39>()
}
fn PLAYER_1() -> ContractAddress {
    contract_address_const::<0x06bd7295fbf481d7c2109d0aca4a0485bb902583d5d6cc7f0307678685209249>()
}
fn PLAYER_2() -> ContractAddress {
    contract_address_const::<0x05f06de98f137297927a239fa9c5b0c8299c7a9700789d5e9e178958f881aae0>()
}
fn PLAYER_3() -> ContractAddress {
    contract_address_const::<0x027d2ad5a55f9be697dd91e479c7b5b279fd2133ac5e6bc11680166a3b86c111>()
}
fn ZERO_TOKEN() -> ContractAddress {
    Zero::zero()
}

// Real contract address deployed on Sepolia
fn ETH_TOKEN_ADDRESS() -> ContractAddress {
    contract_address_const::<0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7>()
}
fn USDC_TOKEN_ADDRESS() -> ContractAddress {
    contract_address_const::<0x053b40a647cedfca6ca84f542a0fe36736031905a9639a7f19a3c1e66bfd5080>()
}

fn STRK_TOKEN_ADDRESS() -> ContractAddress {
    contract_address_const::<0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d>()
}

fn deploy_marquis_contract() -> ContractAddress {
    let contract_class = declare("MarquisCore").unwrap().contract_class();
    let mut calldata = array![];
    calldata.append_serde(OWNER());
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    contract_address
}

fn deploy_ludo_contract() -> ContractAddress {
    let marquis_contract_address = deploy_marquis_contract();

    let contract_class = declare("Ludo").unwrap().contract_class();
    // Todo: Refactor to not use eth
    let oracle_address: felt252 = '0x0';
    let marquis_oracle_address: EthAddress = oracle_address.try_into().unwrap();
    let mut calldata = array![];
    calldata.append_serde(marquis_oracle_address);
    calldata.append_serde(marquis_contract_address);
    let (contract_address, _) = contract_class.deploy(@calldata).unwrap();
    //println!("-- Ludo contract deployed on: {:?}", contract_address);
    contract_address
}

fn deploy_erc20_contract(symbol: ByteArray, address: ContractAddress) -> ContractAddress {
    let contract_class = declare("ERC20").unwrap().contract_class();
    let mut calldata = array![];
    calldata.append_serde(0);
    calldata.append_serde(symbol);
    calldata.append_serde(1000000000000000000000000000);
    calldata.append_serde(OWNER());
    let (contract_address, _) = contract_class.deploy_at(@calldata, address).unwrap();

    let erc20_dispatcher = IERC20Dispatcher { contract_address: contract_address };

    cheat_caller_address(contract_address, OWNER(), CheatSpan::TargetCalls(4));
    erc20_dispatcher.transfer(PLAYER_0(), 1000000);
    erc20_dispatcher.transfer(PLAYER_1(), 1000000);
    erc20_dispatcher.transfer(PLAYER_2(), 1000000);
    erc20_dispatcher.transfer(PLAYER_3(), 1000000);

    contract_address
}

fn upgrade_contract(caller: ContractAddress) {
    let ludo_contract = deploy_ludo_contract();
    let upgradeable_dispatcher = IUpgradeableDispatcher { contract_address: ludo_contract };

    let contract_class = declare("Ludo").unwrap().contract_class();
    // We are going to use another contract (ERC20) to feign as it was a Ludo Upgrade.
    // This should produce a new class hash
    let new_contract_class = declare("ERC20").unwrap().contract_class();
    let class_hash = *contract_class.class_hash;
    let new_class_hash = *new_contract_class.class_hash;
    assert_ne!(class_hash, new_class_hash);

    let mut spy = spy_events();

    // when the caller calls upgrade
    cheat_caller_address(ludo_contract, caller, CheatSpan::TargetCalls(1));
    upgradeable_dispatcher.upgrade(new_class_hash);

    let events_from_ludo_contract = spy.get_events();
    assert_eq!(events_from_ludo_contract.events.len(), 1);

    // Check if the emitted event was as expected with the new class hash.
    spy
        .assert_emitted(
            @array![
                (
                    ludo_contract,
                    UpgradeableComponent::Event::Upgraded(
                        UpgradeableComponent::Upgraded { class_hash: new_class_hash },
                    ),
                ),
            ],
        );
}

// SETUP GAME FUNCTIONS

#[derive(Drop, Copy)]
/// Represents the context of a game session to be shared with utilities functions
struct GameContext {
    ludo_contract: ContractAddress,
    ludo_dispatcher: ILudoDispatcher,
    marquis_game_dispatcher: IMarquisGameDispatcher,
    session_id: u256,
}

/// Utility function to start a new game by player 0
/// - Deploy the Ludo contract
/// - Create and return a new game session context
/// - If the token address is an ETH token, use an ERC20 mock and give allowance to the Ludo
/// contract - Return the initial balance as well; some tests need it
fn setup_game_new(token: ContractAddress, amount: u256) -> (GameContext, u256) {
    let ludo_contract = deploy_ludo_contract();
    let ludo_dispatcher = ILudoDispatcher { contract_address: ludo_contract };
    let marquis_game_dispatcher = IMarquisGameDispatcher { contract_address: ludo_contract };

    let player_0 = PLAYER_0();
    let mut player_0_init_balance = 0;

    if token == ETH_TOKEN_ADDRESS() {
        deploy_erc20_contract("ETH", token);
        let erc20_dispatcher = IERC20Dispatcher { contract_address: token };

        player_0_init_balance = erc20_dispatcher.balance_of(player_0);
        cheat_caller_address(token, player_0, CheatSpan::TargetCalls(1));
        erc20_dispatcher.approve(ludo_contract, amount);

        println!("-- Player 0 balance before joining: {:?}", player_0_init_balance);
    }

    // create session
    cheat_caller_address(ludo_contract, player_0, CheatSpan::TargetCalls(1));
    let session_id = marquis_game_dispatcher.create_session(token, amount);

    let context = GameContext {
        ludo_contract, ludo_dispatcher, marquis_game_dispatcher, session_id,
    };

    (context, player_0_init_balance)
}

/// Utility function to start a new game by player 0
/// - Call setup_game_new() first
/// - Allow 3 more players to join the session
/// - Return all initial balances
fn setup_game_4_players(token: ContractAddress, amount: u256) -> (GameContext, Array<u256>) {
    let (context, player_0_init_balance) = setup_game_new(token, amount);

    let player_1 = PLAYER_1();
    let player_2 = PLAYER_2();
    let player_3 = PLAYER_3();
    let mut player_1_init_balance = 0;
    let mut player_2_init_balance = 0;
    let mut player_3_init_balance = 0;

    if token == ETH_TOKEN_ADDRESS() {
        let erc20_dispatcher = IERC20Dispatcher { contract_address: token };
        player_1_init_balance = erc20_dispatcher.balance_of(player_1);
        player_2_init_balance = erc20_dispatcher.balance_of(player_2);
        player_3_init_balance = erc20_dispatcher.balance_of(player_3);
        cheat_caller_address(token, player_1, CheatSpan::TargetCalls(1));
        erc20_dispatcher.approve(context.ludo_contract, amount);
        cheat_caller_address(token, player_2, CheatSpan::TargetCalls(1));
        erc20_dispatcher.approve(context.ludo_contract, amount);
        cheat_caller_address(token, player_3, CheatSpan::TargetCalls(1));
        erc20_dispatcher.approve(context.ludo_contract, amount);

        println!("-- Player 1 balance before joining: {:?}", player_1_init_balance);
        println!("-- Player 2 balance before joining: {:?}", player_2_init_balance);
        println!("-- Player 3 balance before joining: {:?}", player_3_init_balance);
    }

    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);
    cheat_caller_address(context.ludo_contract, player_2, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);
    cheat_caller_address(context.ludo_contract, player_3, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);

    let players_balance_init = array![
        player_0_init_balance, player_1_init_balance, player_2_init_balance, player_3_init_balance,
    ];
    (context, players_balance_init)
}

/// Let a player move
fn player_move(
    context: GameContext,
    ludo_move: @LudoMove,
    player: ContractAddress,
    ver_rand_num_array: Array<VerifiableRandomNumber>,
) -> (SessionUserStatus, SessionUserStatus, SessionUserStatus, SessionUserStatus) {
    cheat_caller_address(context.ludo_contract, player, CheatSpan::TargetCalls(1));
    println!("-- Playing move for player 0x0{:x}", player);
    context.ludo_dispatcher.play(context.session_id, ludo_move.clone(), ver_rand_num_array);
    let (_, ludo_session_status) = context.ludo_dispatcher.get_session_status(context.session_id);

    //println!("{:?}", session_data);
    //println!("{:?}", ludo_session_status);
    ludo_session_status.users
}

/// Utility function to feign rolls -- generate random numbers using the VerifiableRandomNumber
/// struct
/// @param no_of_rolls: the number of rolls targeted on one die to be made.
/// @param no_of_rolls_batch_size: The batch size to iterate the previous number of rolls.
/// @param r1 The first random number, usually a 6 to move out of the starting position.
/// this parameter is not counted for a single roll, Therefore the number dedicated to a single roll
/// should be put as the last parameter to this function, as the first would be ignored.
/// @param r2 The second random number, the last roll, usually a 2 to win the game.
/// @return an array of rolls batches, with the size of the no_of_rolls_batch_size.
fn generate_verifiable_random_numbers(
    no_of_rolls: usize, no_of_rolls_batch_size: usize, r1: u256, r2: u256,
) -> Array<Array<VerifiableRandomNumber>> {
    let mut ver_rand_num_array = array![];
    for _ in 0..no_of_rolls - 1 {
        ver_rand_num_array.append(VerifiableRandomNumber { random_number: r1, v: 1, r: 1, s: 1 });
    };
    ver_rand_num_array.append(VerifiableRandomNumber { random_number: r2, v: 1, r: 1, s: 1 });

    let mut batch = array![];
    for _ in 0..no_of_rolls_batch_size {
        batch.append(ver_rand_num_array.clone());
    };

    batch
}

/// Utility function to feign a win scenario.
/// - Player 3 always wins
/// @param player_0 - player_3: ContractAddresses of all four players taken in as a ref
/// @param context: The GameContext
/// @return the snapshot of the event generated from the contract.
fn feign_win(
    player_0: @ContractAddress,
    player_1: @ContractAddress,
    player_2: @ContractAddress,
    player_3: @ContractAddress,
    context: @GameContext,
) -> @Event {
    let mut ver_rand_num_array_ref = generate_verifiable_random_numbers(11, 13, 6, 2);
    let player_0 = *player_0;
    let player_1 = *player_1;
    let player_2 = *player_2;
    let player_3 = *player_3;
    let context = *context;

    let ludo_move = LudoMove { token_id: 0 };

    println!("-- Playing move for player 0");
    let (user0, _, _, _) = player_move(
        context, @ludo_move, player_0, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user0_pin_0_pos = 1 + 56;
    assert_position_0_eq(@user0, expected_user0_pin_0_pos);

    println!("-- Playing move for player 1");
    let (_, user1, _, _) = player_move(
        context, @ludo_move, player_1, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user1_pin_0_pos = (14 + 56) % 52;
    assert_position_0_eq(@user1, expected_user1_pin_0_pos);

    println!("-- Playing move for player 2");
    let (_, _, user2, _) = player_move(
        context, @ludo_move, player_2, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_pin_0_pos = (27 + 56) % 52;
    assert_position_0_eq(@user2, expected_pin_0_pos);

    println!("-- Playing move for player 3");
    let (_, _, _, user3) = player_move(
        context, @ludo_move, player_3, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_pin_0_pos = (40 + 56) % 52;
    assert_position_0_eq(@user3, expected_pin_0_pos);

    let ludo_move_1 = LudoMove { token_id: 1 };

    println!("-- Playing move for player 0 pin 1");
    let (user0, _, _, _) = player_move(
        context, @ludo_move_1, player_0, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user0_pin_1_pos = 1 + 56;
    assert_position_1_eq(@user0, expected_user0_pin_1_pos);

    println!("-- Playing move for player 1 pin 1");
    let (_, user1, _, _) = player_move(
        context, @ludo_move_1, player_1, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user1_pin_1_pos = (14 + 56) % 52;
    assert_position_1_eq(@user1, expected_user1_pin_1_pos);

    println!("-- Playing move for player 2 pin 1");
    let (_, _, user2, _) = player_move(
        context, @ludo_move_1, player_2, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user2_pin_1_pos = (27 + 56) % 52;
    assert_position_1_eq(@user2, expected_user2_pin_1_pos);

    println!("-- Playing move for player 3 pin 1");
    let (_, _, _, user3) = player_move(
        context, @ludo_move_1, player_3, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user3_pin_1_pos = (40 + 56) % 52;
    assert_position_1_eq(@user3, expected_user3_pin_1_pos);

    let ludo_move_2 = LudoMove { token_id: 2 };

    println!("-- Playing move for player 0 pin 2");
    let (user0, _, _, _) = player_move(
        context, @ludo_move_2, player_0, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user0_pin_2_pos = 1 + 56;
    assert_position_2_eq(@user0, expected_user0_pin_2_pos);

    println!("-- Playing move for player 1 pin 2");
    let (_, user1, _, _) = player_move(
        context, @ludo_move_2, player_1, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user1_pin_2_pos = (14 + 56) % 52;
    assert_position_2_eq(@user1, expected_user1_pin_2_pos);

    println!("-- Playing move for player 2 pin 2");
    let (_, _, user2, _) = player_move(
        context, @ludo_move_2, player_2, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user2_pin_2_pos = (27 + 56) % 52;
    assert_position_2_eq(@user2, expected_user2_pin_2_pos);

    println!("-- Playing move for player 3 pin 2");
    let (_, _, _, user3) = player_move(
        context, @ludo_move_2, player_3, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user3_pin_2_pos = (40 + 56) % 52;
    assert_position_2_eq(@user3, expected_user3_pin_2_pos);

    let player_session = context.marquis_game_dispatcher.player_session(player_0);
    println!("-- Player 0 session: {:?}", player_session);
    let expected_session_id = 1;
    assert_eq!(player_session, expected_session_id);

    println!("-- Playing move for player 0 pin 3 to win");
    let ludo_move_3 = LudoMove { token_id: 3 };
    let mut spy = spy_events();

    let (user0, _, _, _) = player_move(
        context, @ludo_move_3, player_0, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user0_pin_3_pos = 1 + 56;
    assert_position_3_eq(@user0, expected_user0_pin_3_pos);

    let events_from_ludo_contract = spy.get_events().emitted_by(context.ludo_contract);
    let (from, event_from_ludo) = events_from_ludo_contract.events.at(0);

    let felt_session_id: felt252 = context.session_id.try_into().unwrap();
    assert_eq!(from, @context.ludo_contract);
    assert_eq!(event_from_ludo.keys.at(0), @selector!("SessionFinished"));
    assert_eq!(event_from_ludo.keys.at(1), @felt_session_id);

    let expected_status = 3; // finished
    let expected_player_count = 0;
    let (session_data, ludo_session_status) = context
        .ludo_dispatcher
        .get_session_status(context.session_id);
    println!("{:?}", session_data);
    println!("{:?}", ludo_session_status);
    assert_eq!(session_data.status, expected_status);
    assert_eq!(session_data.player_count, expected_player_count);

    let (_, _, _, user0_pin_3_winning) = user0.player_winning_tokens;
    assert!(user0_pin_3_winning);

    // Check unlock players
    let player_0_session = context.marquis_game_dispatcher.player_session(player_0);
    let expected_session_id = 0;
    assert_eq!(player_0_session, expected_session_id);

    let player_1_session = context.marquis_game_dispatcher.player_session(player_1);
    let expected_player_1_session = 0;
    assert_eq!(player_1_session, expected_player_1_session);

    let player_2_session = context.marquis_game_dispatcher.player_session(player_2);
    let expected_player_2_session = 0;
    assert_eq!(player_2_session, expected_player_2_session);

    let player_3_session = context.marquis_game_dispatcher.player_session(player_3);
    let expected_player_3_session = 0;
    assert_eq!(player_3_session, expected_player_3_session);

    event_from_ludo
}

fn assert_position_0_eq(user: @SessionUserStatus, expected_pos: u256) {
    let (pos_0, _, _, _) = *user.player_tokens_position;
    println!("-- User {:?} pin 0 pos: {:?}", user.player_id, pos_0);
    assert_eq!(pos_0, expected_pos);
}

fn assert_position_1_eq(user: @SessionUserStatus, expected_pos: u256) {
    let (_, pos_1, _, _) = *user.player_tokens_position;
    println!("-- User {:?} pin 1 pos: {:?}", user.player_id, pos_1);
    assert_eq!(pos_1, expected_pos);
}

fn assert_position_2_eq(user: @SessionUserStatus, expected_pos: u256) {
    let (_, _, pos_2, _) = *user.player_tokens_position;
    println!("-- User {:?} pin 2 pos: {:?}", user.player_id, pos_2);
    assert_eq!(pos_2, expected_pos);
}

fn assert_position_3_eq(user: @SessionUserStatus, expected_pos: u256) {
    let (_, _, _, pos_3) = *user.player_tokens_position;
    println!("-- User {:?} pin 3 pos: {:?}", user.player_id, pos_3);
    assert_eq!(pos_3, expected_pos);
}

// MARQUIS CONTRACT TESTS

#[test]
fn should_deploy_marquis_contract() {
    deploy_marquis_contract();
}

#[test]
fn should_add_supported_token_successfully() {
    let marquis_contract = deploy_marquis_contract();
    let marquis_dispatcher = IMarquisCoreDispatcher { contract_address: marquis_contract };
    let token_address = USDC_TOKEN_ADDRESS();
    let fee = 1;
    let supported_token = SupportedToken { token_address, fee };
    cheat_caller_address(marquis_contract, OWNER(), CheatSpan::TargetCalls(1));
    marquis_dispatcher.add_supported_token(supported_token);
}

#[test]
fn should_update_token_fee_when_owner() {
    let marquis_contract = deploy_marquis_contract();
    let marquis_dispatcher = IMarquisCoreDispatcher { contract_address: marquis_contract };
    let new_fee = 10;
    let token_index = 0;
    cheat_caller_address(marquis_contract, OWNER(), CheatSpan::TargetCalls(1));
    marquis_dispatcher.update_token_fee(token_index, new_fee);
    let mut vec_supported_token = marquis_dispatcher.get_all_supported_tokens();
    let supported_token = vec_supported_token.pop_front().unwrap();
    assert_eq!(*supported_token.fee, new_fee);
}

#[test]
fn should_withdraw_specified_amount_from_contract() {
    let marquis_contract = deploy_marquis_contract();
    let strk_token_address = deploy_erc20_contract("STRK", STRK_TOKEN_ADDRESS());
    let owner = OWNER();
    let marquis_dispatcher = IMarquisCoreDispatcher { contract_address: marquis_contract };
    let erc20_dispatcher = IERC20Dispatcher { contract_address: strk_token_address };
    let marquis_init_balance = erc20_dispatcher.balance_of(marquis_contract);
    cheat_caller_address(strk_token_address, owner, CheatSpan::TargetCalls(1));
    erc20_dispatcher.approve(marquis_contract, 1000);
    cheat_caller_address(strk_token_address, owner, CheatSpan::TargetCalls(1));
    erc20_dispatcher.transfer(marquis_contract, 1000);
    let marquis_balance_before_withdraw = erc20_dispatcher.balance_of(marquis_contract);
    assert_eq!(marquis_balance_before_withdraw, marquis_init_balance + 1000);

    let beneficiary = PLAYER_1();
    let amount = 100;
    let beneficiary_init_balance = erc20_dispatcher.balance_of(beneficiary);
    cheat_caller_address(marquis_contract, OWNER(), CheatSpan::TargetCalls(1));
    marquis_dispatcher.withdraw(strk_token_address, beneficiary, Option::Some(amount));
    let beneficiary_balance = erc20_dispatcher.balance_of(beneficiary);
    assert_eq!(beneficiary_balance, beneficiary_init_balance + amount);
    let marquis_balance_after_withdraw = erc20_dispatcher.balance_of(marquis_contract);
    assert_eq!(marquis_balance_after_withdraw, marquis_balance_before_withdraw - amount);
}

#[test]
fn should_withdraw_all_funds_from_contract() {
    let marquis_contract = deploy_marquis_contract();
    let strk_token_address = deploy_erc20_contract("STRK", STRK_TOKEN_ADDRESS());
    let owner = OWNER();
    let marquis_dispatcher = IMarquisCoreDispatcher { contract_address: marquis_contract };
    let erc20_dispatcher = IERC20Dispatcher { contract_address: strk_token_address };
    let marquis_init_balance = erc20_dispatcher.balance_of(marquis_contract);
    cheat_caller_address(strk_token_address, owner, CheatSpan::TargetCalls(1));
    erc20_dispatcher.approve(marquis_contract, 1000);
    cheat_caller_address(strk_token_address, owner, CheatSpan::TargetCalls(1));
    erc20_dispatcher.transfer(marquis_contract, 1000);
    let marquis_balance_before_withdraw = erc20_dispatcher.balance_of(marquis_contract);
    assert_eq!(marquis_balance_before_withdraw, marquis_init_balance + 1000);

    let beneficiary = PLAYER_1();
    let beneficiary_init_balance = erc20_dispatcher.balance_of(beneficiary);
    cheat_caller_address(marquis_contract, OWNER(), CheatSpan::TargetCalls(1));
    marquis_dispatcher.withdraw(strk_token_address, beneficiary, Option::None);
    let beneficiary_balance = erc20_dispatcher.balance_of(beneficiary);
    assert_eq!(beneficiary_balance, beneficiary_init_balance + marquis_balance_before_withdraw);
    let marquis_balance_after_withdraw = erc20_dispatcher.balance_of(marquis_contract);
    assert_eq!(marquis_balance_after_withdraw, 0);
}

#[test]
fn should_return_all_supported_tokens() {
    let marquis_contract = deploy_marquis_contract();
    let marquis_dispatcher = IMarquisCoreDispatcher { contract_address: marquis_contract };
    let token_address = STRK_TOKEN_ADDRESS();
    let fee = Constants::FEE_MIN;
    let mut vec_tokens = marquis_dispatcher.get_all_supported_tokens();
    let token = vec_tokens.pop_front().unwrap();
    println!("{:?}", token);
    assert_eq!(*token.token_address, token_address);
    assert_eq!(*token.fee, fee);
}

// LUDO CONTRACT TESTS

#[test]
fn should_deploy_ludo_contract() {
    deploy_ludo_contract();
}

#[test]
fn should_return_correct_game_name() {
    let ludo_contract = deploy_ludo_contract();
    let marquis_game_dispatcher = IMarquisGameDispatcher { contract_address: ludo_contract };
    let expected_name = "Ludo";
    let name = marquis_game_dispatcher.name();
    assert_eq!(name, expected_name);
}

#[test]
fn should_create_new_game_session() {
    let ludo_contract = deploy_ludo_contract();
    let marquis_game_dispatcher = IMarquisGameDispatcher { contract_address: ludo_contract };
    let token = ZERO_TOKEN();
    let amount = 0;
    let session_id = marquis_game_dispatcher.create_session(token, amount);
    let expected_session_id = 1;
    assert_eq!(session_id, expected_session_id);
}

#[test]
fn should_create_new_game_session_with_eth_token_deposit() {
    // given a new game
    let eth_contract_address = ETH_TOKEN_ADDRESS();
    let amount = 100;
    let (context, player_0_init_balance) = setup_game_new(eth_contract_address, amount);

    let expected_session_id = 1;
    let erc20_dispatcher = IERC20Dispatcher { contract_address: eth_contract_address };

    // then check deposit
    let player_0 = PLAYER_0();
    let player_balance_after = erc20_dispatcher.balance_of(player_0);
    assert_eq!(player_0_init_balance - player_balance_after, amount);
    assert_eq!(context.session_id, expected_session_id);
}

#[test]
fn should_allow_player_to_join_session() {
    // given a new game
    let (context, _) = setup_game_new(ZERO_TOKEN(), 0);

    // when a player join session
    let player_1 = PLAYER_1();
    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);

    // then check session status
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);
    let player_count = session_data.player_count;
    let status = session_data.status;
    let expected_player_count = 2;
    let expected_status = 1; // waiting for players
    assert_eq!(player_count, expected_player_count);
    assert_eq!(status, expected_status);
}

#[test]
fn should_allow_player_to_join_with_eth_token_stake() {
    // given a new game
    let eth_contract_address = ETH_TOKEN_ADDRESS();
    let amount = 100;
    let (context, player_0_init_balance) = setup_game_new(eth_contract_address, amount);

    let player_0 = PLAYER_0();
    let player_1 = PLAYER_1();
    let erc20_dispatcher = IERC20Dispatcher { contract_address: eth_contract_address };
    let player_1_init_balance = erc20_dispatcher.balance_of(player_1);

    // when a player join session
    cheat_caller_address(eth_contract_address, player_1, CheatSpan::TargetCalls(1));
    erc20_dispatcher.approve(context.ludo_contract, amount);
    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);

    // then check session status
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);
    let player_count = session_data.player_count;
    let status = session_data.status;
    let expected_player_count = 2;
    let expected_status = 1; // waiting for players
    assert_eq!(player_count, expected_player_count);
    assert_eq!(status, expected_status);

    // then check players stacke
    let player_0_balance_after_join = erc20_dispatcher.balance_of(player_0);
    println!("-- Player 0 balance after joining: {:?}", player_0_balance_after_join);
    assert_eq!(player_0_balance_after_join, player_0_init_balance - amount);
    let player_1_balance_after_join = erc20_dispatcher.balance_of(player_1);
    println!("-- Player 1 balance after joining: {:?}", player_1_balance_after_join);
    assert_eq!(player_1_balance_after_join, player_1_init_balance - amount);
}

#[test]
fn should_require_four_players_to_start_game() {
    // given a new game
    let (context, _) = setup_game_new(ZERO_TOKEN(), 0);

    // when 2 players join
    let player_1 = PLAYER_1();
    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);

    let player_2 = PLAYER_2();
    cheat_caller_address(context.ludo_contract, player_2, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);

    // then game is WAITING
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);
    let player_count = session_data.player_count;
    let status = session_data.status;
    let expected_player_count = 3;
    let expected_status = 1; // waiting for players
    assert_eq!(player_count, expected_player_count);
    assert_eq!(status, expected_status);

    // when a 3rd player join
    let player_3 = PLAYER_3();
    cheat_caller_address(context.ludo_contract, player_3, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);

    // then game is ready
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);
    let player_count = session_data.player_count;
    let status = session_data.status;
    let expected_player_count = 4;
    let expected_status = 2; // can play
    assert_eq!(player_count, expected_player_count);
    assert_eq!(status, expected_status);

    println!("-- Session data: {:?}", session_data);
}

#[test]
fn should_allow_player_0_to_finish_before_game_starts_with_zero_token_stake() {
    // given a new game
    let (context, _) = setup_game_new(ZERO_TOKEN(), 0);
    let player_0 = PLAYER_0();

    // then check status
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);
    let status = session_data.status;
    let expected_status = 1; // waiting for players
    assert_eq!(status, expected_status);
    let nonce = session_data.nonce;
    println!("-- Session data, nonce: {:?}", nonce);

    // when player 0 finish session
    let mut spy = spy_events();
    cheat_caller_address(context.ludo_contract, player_0, CheatSpan::TargetCalls(1));
    let option_loser_id = Option::None;
    context.marquis_game_dispatcher.player_finish_session(context.session_id, option_loser_id);

    // then verify ForcedSessionFinished event was emitted
    let events = spy.get_events().emitted_by(context.ludo_contract);
    let (from, event) = events.events.at(0);
    let felt_session_id: felt252 = context.session_id.try_into().unwrap();
    assert_eq!(from, @context.ludo_contract);
    assert_eq!(event.keys.at(0), @selector!("ForcedSessionFinished"));
    assert_eq!(event.keys.at(1), @felt_session_id);

    // then session is finished
    let (session_data, ludo_session_status) = context
        .ludo_dispatcher
        .get_session_status(context.session_id);
    println!("{:?}", session_data);
    println!("{:?}", ludo_session_status);
    let status = session_data.status;
    let expected_status = 3; // finished
    assert_eq!(status, expected_status);

    // then no player session
    let player_0_session = context.marquis_game_dispatcher.player_session(player_0);
    let expected_player_0_session = 0; // no session
    assert_eq!(player_0_session, expected_player_0_session);

    // player 0 can create a new session
    let token = ZERO_TOKEN();
    let amount = 0;
    cheat_caller_address(context.ludo_contract, player_0, CheatSpan::TargetCalls(1));
    let new_session_id = context.marquis_game_dispatcher.create_session(token, amount);
    let expected_session_id = 2;
    assert_eq!(new_session_id, expected_session_id);
}

#[test]
fn should_allow_player_0_to_finish_before_game_starts_with_eth_token_stake() {
    // given a new game with ETH stakes
    let eth_contract_address = ETH_TOKEN_ADDRESS();
    let amount = 100;
    let (context, player_0_init_balance) = setup_game_new(eth_contract_address, amount);
    let player_0 = PLAYER_0();

    // when player 0 finishes session
    cheat_caller_address(context.ludo_contract, player_0, CheatSpan::TargetCalls(1));
    let option_loser_id = Option::None;
    context.marquis_game_dispatcher.player_finish_session(context.session_id, option_loser_id);
    println!("-- Player 0 finished session");

    // then session is finished
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);
    let status = session_data.status;
    let expected_status = 3; // finished
    assert_eq!(status, expected_status);

    // then verify players got their stakes back
    let erc20_dispatcher = IERC20Dispatcher { contract_address: eth_contract_address };
    let player_0_balance_after = erc20_dispatcher.balance_of(player_0);

    println!("-- Player 0 balance after finish: {:?}", player_0_balance_after);

    assert_eq!(player_0_balance_after, player_0_init_balance);

    // then verify players are unlocked
    let player_0_session = context.marquis_game_dispatcher.player_session(player_0);
    let expected_no_session = 0;
    assert_eq!(player_0_session, expected_no_session);
}

#[test]
fn should_allow_player_1_to_finish_before_game_starts_with_zero_token_stake() {
    // given a new game
    let (context, _) = setup_game_new(ZERO_TOKEN(), 0);
    let player_0 = PLAYER_0();

    // when a player join the session
    let player_1 = PLAYER_1();
    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);

    // then check session status
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);
    let status = session_data.status;
    let expected_status = 1; // waiting for players
    assert_eq!(status, expected_status);
    let nonce = session_data.nonce;
    println!("-- Session data, nonce: {:?}", nonce);

    // when a player finish the session
    let mut spy = spy_events();
    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    let option_loser_id = Option::None;
    context.marquis_game_dispatcher.player_finish_session(context.session_id, option_loser_id);

    // then verify ForcedSessionFinished event was emitted
    let events = spy.get_events().emitted_by(context.ludo_contract);
    let (from, event) = events.events.at(0);
    let felt_session_id: felt252 = context.session_id.try_into().unwrap();
    assert_eq!(from, @context.ludo_contract);
    assert_eq!(event.keys.at(0), @selector!("ForcedSessionFinished"));
    assert_eq!(event.keys.at(1), @felt_session_id);

    // then session must be finished
    let (session_data, ludo_session_status) = context
        .ludo_dispatcher
        .get_session_status(context.session_id);
    println!("{:?}", session_data);
    println!("{:?}", ludo_session_status);
    let status = session_data.status;
    let expected_status = 3; // finished
    assert_eq!(status, expected_status);

    // then check player session
    let player_0_session = context.marquis_game_dispatcher.player_session(player_0);
    let expected_player_1_session = 0; // no session
    assert_eq!(player_0_session, expected_player_1_session);
    let player_1_session = context.marquis_game_dispatcher.player_session(player_1);
    println!("player_1_session: {:?}", player_1_session);
    assert_eq!(player_1_session, expected_player_1_session);

    // player 1 can create a new session
    let token = ZERO_TOKEN();
    let amount = 0;
    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    let new_session_id = context.marquis_game_dispatcher.create_session(token, amount);
    println!("let new_session_id: {:?}", new_session_id);
}

#[test]
fn should_allow_player_1_to_finish_before_game_starts_with_eth_token_stake() {
    // given a new game with ETH stakes
    let eth_contract_address = ETH_TOKEN_ADDRESS();
    let amount = 100;
    let (context, _) = setup_game_new(eth_contract_address, amount);

    // when player 1 joins the session
    let player_1 = PLAYER_1();
    let erc20_dispatcher = IERC20Dispatcher { contract_address: eth_contract_address };
    let player_1_init_balance = erc20_dispatcher.balance_of(player_1);

    cheat_caller_address(eth_contract_address, player_1, CheatSpan::TargetCalls(1));
    erc20_dispatcher.approve(context.ludo_contract, amount);
    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);

    // when player 1 finishes session
    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    let option_loser_id = Option::None;
    context.marquis_game_dispatcher.player_finish_session(context.session_id, option_loser_id);
    println!("-- Player 1 finished session");

    // then session is finished
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);
    let status = session_data.status;
    let expected_status = 3; // finished
    assert_eq!(status, expected_status);

    // then verify players got their stakes back
    let player_1_balance_after = erc20_dispatcher.balance_of(player_1);
    println!("-- Player 1 balance after finish: {:?}", player_1_balance_after);
    assert_eq!(player_1_balance_after, player_1_init_balance);

    // then verify players are unlocked
    let player_1_session = context.marquis_game_dispatcher.player_session(player_1);
    let expected_no_session = 0;
    assert_eq!(player_1_session, expected_no_session);
}

#[test]
fn should_allow_player_to_finish_ongoing_game_with_zero_token_stake() {
    // given a new game
    let (context, _) = setup_game_4_players(ZERO_TOKEN(), 0);
    let player_0 = PLAYER_0();
    let player_1 = PLAYER_1();

    // when player 1 finish session
    let mut spy = spy_events();
    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    let option_loser_id = Option::None;
    context.marquis_game_dispatcher.player_finish_session(context.session_id, option_loser_id);

    // then verify ForcedSessionFinished event was emitted
    let events = spy.get_events().emitted_by(context.ludo_contract);
    let (from, event) = events.events.at(0);
    let felt_session_id: felt252 = context.session_id.try_into().unwrap();
    assert_eq!(from, @context.ludo_contract);
    assert_eq!(event.keys.at(0), @selector!("ForcedSessionFinished"));
    assert_eq!(event.keys.at(1), @felt_session_id);

    // then session is finished
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);
    println!("{:?}", session_data);
    let status = session_data.status;
    let expected_status = 3; // finished
    assert_eq!(status, expected_status);

    // player 0 can create a new session
    let token = ZERO_TOKEN();
    let amount = 0;
    cheat_caller_address(context.ludo_contract, player_0, CheatSpan::TargetCalls(1));
    let new_session_id = context.marquis_game_dispatcher.create_session(token, amount);
    println!("let new_session_id: {:?}", new_session_id);

    // player 1 can join the new session
    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(new_session_id);
}

#[test]
fn should_allow_player_1_to_finish_ongoing_game_with_eth_token_stake() {
    // given a new game with ETH stakes
    let eth_contract_address = ETH_TOKEN_ADDRESS();
    let amount = 100000;
    let (context, players_balance_init) = setup_game_4_players(eth_contract_address, amount);

    let player_0 = PLAYER_0();
    let player_1 = PLAYER_1();
    let erc20_dispatcher = IERC20Dispatcher { contract_address: eth_contract_address };

    // when player 1 finishes session
    let mut spy = spy_events();
    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    let player_1_id = 1;
    let option_loser_id = Option::Some(player_1_id);
    context.marquis_game_dispatcher.player_finish_session(context.session_id, option_loser_id);

    // then verify ForcedSessionFinished event was emitted
    let events = spy.get_events().emitted_by(context.ludo_contract);
    let (from, event) = events.events.at(0);
    let felt_session_id: felt252 = context.session_id.try_into().unwrap();
    assert_eq!(from, @context.ludo_contract);
    assert_eq!(event.keys.at(0), @selector!("ForcedSessionFinished"));
    assert_eq!(event.keys.at(1), @felt_session_id);

    // then session is finished
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);
    let status = session_data.status;
    let expected_status = 3; // finished
    assert_eq!(status, expected_status);

    // then verify player 0 got 1/3 of the total stake and player 1 lost all his stake
    let player_0_balance_after = erc20_dispatcher.balance_of(player_0);
    let player_1_balance_after = erc20_dispatcher.balance_of(player_1);

    println!("-- Player 0 balance after finish: {:?}", player_0_balance_after);
    println!("-- Player 1 balance after finish: {:?}", player_1_balance_after);

    assert_eq!(player_0_balance_after, *players_balance_init[0] + amount / 3);
    assert_eq!(player_1_balance_after, *players_balance_init[1] - amount);

    // then verify players are unlocked
    let player_0_session = context.marquis_game_dispatcher.player_session(player_0);
    let player_1_session = context.marquis_game_dispatcher.player_session(player_1);
    let expected_no_session = 0;
    assert_eq!(player_0_session, expected_no_session);
    assert_eq!(player_1_session, expected_no_session);

    // player 0 can create a new session
    cheat_caller_address(eth_contract_address, player_0, CheatSpan::TargetCalls(1));
    erc20_dispatcher.approve(context.ludo_contract, amount);

    cheat_caller_address(context.ludo_contract, player_0, CheatSpan::TargetCalls(1));
    let new_session_id = context
        .marquis_game_dispatcher
        .create_session(eth_contract_address, amount);
    let expected_new_session_id = 2;
    assert_eq!(new_session_id, expected_new_session_id);
}

#[test]
fn should_allow_player_3_to_finish_ongoing_game_with_eth_token_stake() {
    // given a new game
    let eth_contract_address = ETH_TOKEN_ADDRESS();
    let amount = 30000;
    let (context, players_balance_init) = setup_game_4_players(eth_contract_address, amount);

    let player_3 = PLAYER_3();
    let erc20_dispatcher = IERC20Dispatcher { contract_address: eth_contract_address };

    // when player 1 finish session
    let mut spy = spy_events();
    let player_3_id = 3;
    cheat_caller_address(context.ludo_contract, player_3, CheatSpan::TargetCalls(1));
    let option_loser_id = Option::Some(player_3_id);
    context.marquis_game_dispatcher.player_finish_session(context.session_id, option_loser_id);

    // then verify ForcedSessionFinished event was emitted
    let events = spy.get_events().emitted_by(context.ludo_contract);
    let (from, event) = events.events.at(0);
    let felt_session_id: felt252 = context.session_id.try_into().unwrap();
    assert_eq!(from, @context.ludo_contract);
    assert_eq!(event.keys.at(0), @selector!("ForcedSessionFinished"));
    assert_eq!(event.keys.at(1), @felt_session_id);

    // then check status
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);
    println!("{:?}", session_data);
    let status = session_data.status;
    let expected_status = 3; // finished
    assert_eq!(status, expected_status);

    // then split player 1 stake into other player
    let player_0_balance_after = erc20_dispatcher.balance_of(PLAYER_0());
    let player_1_balance_after = erc20_dispatcher.balance_of(PLAYER_1());
    let player_2_balance_after = erc20_dispatcher.balance_of(PLAYER_2());
    let player_3_balance_after = erc20_dispatcher.balance_of(PLAYER_3());
    let player_0_expected_balance = *players_balance_init[0] + amount / 3;
    let player_1_expected_balance = *players_balance_init[1] + amount / 3;
    let player_2_expected_balance = *players_balance_init[2] + amount / 3;
    let player_3_expected_balance = *players_balance_init[3] - amount;
    assert_eq!(player_0_balance_after, player_0_expected_balance);
    assert_eq!(player_1_balance_after, player_1_expected_balance);
    assert_eq!(player_2_balance_after, player_2_expected_balance);
    assert_eq!(player_3_balance_after, player_3_expected_balance);
}

#[test]
fn should_allow_owner_to_force_finish_ongoing_game_with_zero_token_stake() {
    // given a new game
    let (context, _) = setup_game_4_players(ZERO_TOKEN(), 0);
    let owner = OWNER();

    // when owner finish session
    cheat_caller_address(context.ludo_contract, owner, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.owner_finish_session(context.session_id, Option::None);
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);

    // then session is finished
    println!("{:?}", session_data);
    let status = session_data.status;
    let expected_status = 3; // finished
    assert_eq!(status, expected_status);
}

#[test]
fn should_refund_eth_when_owner_finishes_game() {
    // given a new game
    let eth_contract_address = ETH_TOKEN_ADDRESS();
    let amount = 10000;
    let (context, players_balance_init) = setup_game_4_players(eth_contract_address, amount);

    // when owner finish session
    let owner = OWNER();
    cheat_caller_address(context.ludo_contract, owner, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.owner_finish_session(context.session_id, Option::None);

    // then check status
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);
    println!("{:?}", session_data);
    let status = session_data.status;
    let expected_status = 3; // finished
    assert_eq!(status, expected_status);

    // then refund all players
    let erc20_dispatcher = IERC20Dispatcher { contract_address: eth_contract_address };
    let player_0_balance_after = erc20_dispatcher.balance_of(PLAYER_0());
    let player_1_balance_after = erc20_dispatcher.balance_of(PLAYER_1());
    let player_2_balance_after = erc20_dispatcher.balance_of(PLAYER_2());
    let player_3_balance_after = erc20_dispatcher.balance_of(PLAYER_3());
    assert_eq!(player_0_balance_after, *players_balance_init[0]);
    assert_eq!(player_1_balance_after, *players_balance_init[1]);
    assert_eq!(player_2_balance_after, *players_balance_init[2]);
    assert_eq!(player_3_balance_after, *players_balance_init[3]);
}
#[test]
fn should_allow_move_when_rolling_six() {
    // given a new game
    let (context, _) = setup_game_4_players(ZERO_TOKEN(), 0);
    let player_0 = PLAYER_0();

    // when rolling six
    let ludo_move = LudoMove { token_id: 0 };
    // Two rolls here. Roll a six and a two.
    let mut ver_rand_num_array_ref = generate_verifiable_random_numbers(2, 1, 6, 2);
    let (user0, _, _, _) = player_move(
        context, @ludo_move, player_0, ver_rand_num_array_ref.pop_front().unwrap(),
    );

    // then position changed
    let expected_pin_0_pos = 3;
    assert_position_0_eq(@user0, expected_pin_0_pos);
}

#[test]
fn should_skip_turn_when_not_rolling_six() {
    let player_0 = PLAYER_0();
    let player_1 = PLAYER_1();

    // given a new game
    let (context, _) = setup_game_4_players(ZERO_TOKEN(), 0);

    // when player 0 rolling other than six
    let ludo_move = LudoMove { token_id: 0 };
    // Roll a two
    let mut ver_rand_num_array_ref = generate_verifiable_random_numbers(1, 1, 2, 2);

    // then position not change
    let (user0, _, _, _) = player_move(
        context, @ludo_move, player_0, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_pin_0_pos = 0;
    assert_position_0_eq(@user0, expected_pin_0_pos);

    // when player 1 rolling six
    // A 6 and a 2 is rolled here.
    let mut ver_rand_num_array_ref = generate_verifiable_random_numbers(2, 1, 6, 2);

    // then position changed
    let (_, user1, _, _) = player_move(
        context, @ludo_move, player_1, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_pin_0_pos = 14 + 2;
    assert_position_0_eq(@user1, expected_pin_0_pos);
}

#[test]
fn should_kill_opponent_token_on_same_position() {
    let player_0 = PLAYER_0();
    let player_1 = PLAYER_1();
    let player_2 = PLAYER_2();
    let player_3 = PLAYER_3();

    // given a new game
    let (context, _) = setup_game_4_players(ZERO_TOKEN(), 0);

    // when all players move same
    let mut ver_rand_num_array_ref = generate_verifiable_random_numbers(2, 4, 6, 2);

    let ludo_move = LudoMove { token_id: 0 };

    let (user0, _, _, _) = player_move(
        context, @ludo_move, player_0, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user0_pin_0_pos = 1 + 2;
    assert_position_0_eq(@user0, expected_user0_pin_0_pos);

    println!("-- Playing move for player 1");
    let (_, user1, _, _) = player_move(
        context, @ludo_move, player_1, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_use1_pin_0_pos = 14 + 2;
    assert_position_0_eq(@user1, expected_use1_pin_0_pos);

    println!("-- Playing move for player 2");
    let (_, _, user2, _) = player_move(
        context, @ludo_move, player_2, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_pin_0_pos = 27 + 2;
    assert_position_0_eq(@user2, expected_pin_0_pos);

    println!("-- Playing move for player 3");
    let (_, _, _, user3) = player_move(
        context, @ludo_move, player_3, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_pin_0_pos = 40 + 2;
    assert_position_0_eq(@user3, expected_pin_0_pos);

    println!("-- Playing move for player 0 again");
    let mut ver_rand_num_array_ref = generate_verifiable_random_numbers(3, 1, 6, 1);
    let (user0, user1, _, _) = player_move(
        context, @ludo_move, player_0, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let new_expected_user0_pin_0_pos = expected_user0_pin_0_pos + 13;
    assert_position_0_eq(@user0, new_expected_user0_pin_0_pos);
    assert_position_0_eq(@user1, 0);
}

#[test]
fn should_win_when_player_reaches_home() {
    let player_0 = PLAYER_0();
    let player_1 = PLAYER_1();
    let player_2 = PLAYER_2();
    let player_3 = PLAYER_3();

    // given a new game
    let (context, _) = setup_game_4_players(ZERO_TOKEN(), 0);

    let mut ver_rand_num_array_ref = generate_verifiable_random_numbers(10, 4, 6, 2);

    let ludo_move = LudoMove { token_id: 0 };

    println!("-- Playing move for player 0");
    let (user0, _, _, _) = player_move(
        context, @ludo_move, player_0, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user0_pin_0_pos = 1 + 50;
    assert_position_0_eq(@user0, expected_user0_pin_0_pos);

    println!("-- Playing move for player 1");
    let (_, user1, _, _) = player_move(
        context, @ludo_move, player_1, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_use1_pin_0_pos = (14 + 50) % 52;
    assert_position_0_eq(@user1, expected_use1_pin_0_pos);

    println!("-- Playing move for player 2");
    let (_, _, user2, _) = player_move(
        context, @ludo_move, player_2, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_pin_0_pos = (27 + 50) % 52;
    assert_position_0_eq(@user2, expected_pin_0_pos);

    println!("-- Playing move for player 3");
    let (_, _, _, user3) = player_move(
        context, @ludo_move, player_3, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_pin_0_pos = (40 + 50) % 52;
    assert_position_0_eq(@user3, expected_pin_0_pos);

    println!("-- Playing move for player 0 again");
    // this move makes player 0 win. Roll a six.
    let mut ver_rand_num_array = generate_verifiable_random_numbers(1, 1, 0, 6);
    let (user0, _, _, _) = player_move(
        context, @ludo_move, player_0, ver_rand_num_array.pop_front().unwrap(),
    );
    let new_expected_user0_pin_0_pos = expected_user0_pin_0_pos + 6;
    assert_position_0_eq(@user0, new_expected_user0_pin_0_pos);

    let (user0_pin_0_winning, _, _, _) = user0.player_winning_tokens;
    assert!(user0_pin_0_winning);
}

#[test]
// Player 0 kills player 1 circled pin0
fn should_kill_opponent_token_after_full_circle() {
    let player_0 = PLAYER_0();
    let player_1 = PLAYER_1();
    let player_2 = PLAYER_2();
    let player_3 = PLAYER_3();

    // given a new game
    let (context, _) = setup_game_4_players(ZERO_TOKEN(), 0);
    let mut ver_rand_num_array_ref1 = generate_verifiable_random_numbers(2, 3, 6, 2);

    let ludo_move = LudoMove { token_id: 0 };

    println!("-- Playing move for player 0");
    let (user0, _, _, _) = player_move(
        context, @ludo_move, player_0, ver_rand_num_array_ref1.pop_front().unwrap(),
    );
    let expected_user0_pin_0_pos = 1 + 2;
    assert_position_0_eq(@user0, expected_user0_pin_0_pos);

    println!("-- Playing move for player 1");
    let mut ver_rand_num_array_ref2 = generate_verifiable_random_numbers(8, 1, 6, 6);
    let (_, user1, _, _) = player_move(
        context, @ludo_move, player_1, ver_rand_num_array_ref2.pop_front().unwrap(),
    );
    let (user1_pin_0_circled, _, _, _) = user1.player_tokens_circled;
    let expected_use1_pin_0_pos = (14 + 42) % 52;
    assert_position_0_eq(@user1, expected_use1_pin_0_pos);
    assert!(user1_pin_0_circled);

    println!("-- Playing move for player 2");
    let (_, _, user2, _) = player_move(
        context, @ludo_move, player_2, ver_rand_num_array_ref1.pop_front().unwrap(),
    );
    let expected_pin_0_pos = 27 + 2;
    assert_position_0_eq(@user2, expected_pin_0_pos);

    println!("-- Playing move for player 3");
    let (_, _, _, user3) = player_move(
        context, @ludo_move, player_3, ver_rand_num_array_ref1.pop_front().unwrap(),
    );
    let expected_pin_0_pos = 40 + 2;
    assert_position_0_eq(@user3, expected_pin_0_pos);

    println!("-- Playing move for player 0 again");
    let mut ver_rand_num_array = generate_verifiable_random_numbers(1, 1, 0, 1);
    let (user0, user1, _, _) = player_move(
        context, @ludo_move, player_0, ver_rand_num_array.pop_front().unwrap(),
    );
    let (user0_pin_0_pos, _, _, _) = user0.player_tokens_position;
    let (user1_pin_0_pos, _, _, _) = user1.player_tokens_position;
    let (user1_pin_0_circled, _, _, _) = user1.player_tokens_circled;
    let new_expected_user0_pin_0_pos = expected_user0_pin_0_pos + 1;
    println!("-- User 0 pin 0 pos: {:?}", user0_pin_0_pos);
    println!("-- User 1 pin 0 pos: {:?}", user1_pin_0_pos);
    assert_eq!(user0_pin_0_pos, new_expected_user0_pin_0_pos);
    assert_eq!(user1_pin_0_pos, 0);
    assert!(!user1_pin_0_circled);
}

#[test]
fn should_allow_all_player_to_reach_home() {
    let player_0 = PLAYER_0();
    let player_1 = PLAYER_1();
    let player_2 = PLAYER_2();
    let player_3 = PLAYER_3();

    // given a new game
    let (context, _) = setup_game_4_players(ZERO_TOKEN(), 0);
    let mut ver_rand_num_array_ref = generate_verifiable_random_numbers(11, 4, 6, 2);
    let ludo_move = LudoMove { token_id: 0 };

    println!("-- Playing move for player 0");
    let (user0, _, _, _) = player_move(
        context, @ludo_move, player_0, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_user0_pin_0_pos = 1 + 56;
    assert_position_0_eq(@user0, expected_user0_pin_0_pos);

    println!("-- Playing move for player 1");
    let (_, user1, _, _) = player_move(
        context, @ludo_move, player_1, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_use1_pin_0_pos = (14 + 56) % 52;
    assert_position_0_eq(@user1, expected_use1_pin_0_pos);

    println!("-- Playing move for player 2");
    let (_, _, user2, _) = player_move(
        context, @ludo_move, player_2, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_pin_0_pos = (27 + 56) % 52;
    assert_position_0_eq(@user2, expected_pin_0_pos);

    println!("-- Playing move for player 3");
    let (user0, user1, user2, user3) = player_move(
        context, @ludo_move, player_3, ver_rand_num_array_ref.pop_front().unwrap(),
    );
    let expected_pin_0_pos = (40 + 56) % 52;
    assert_position_0_eq(@user3, expected_pin_0_pos);

    let (user0_pin_0_winning, _, _, _) = user0.player_winning_tokens;
    let (user1_pin_0_winning, _, _, _) = user1.player_winning_tokens;
    let (user2_pin_0_winning, _, _, _) = user2.player_winning_tokens;
    let (user3_pin_0_winning, _, _, _) = user3.player_winning_tokens;
    assert!(user0_pin_0_winning);
    assert!(user1_pin_0_winning);
    assert!(user2_pin_0_winning);
    assert!(user3_pin_0_winning);
}

#[test]
fn should_end_game_when_player_wins_with_all_tokens() {
    let player_0 = PLAYER_0();
    let player_1 = PLAYER_1();
    let player_2 = PLAYER_2();
    let player_3 = PLAYER_3();

    // given a new game
    let (context, _) = setup_game_4_players(ZERO_TOKEN(), 0);
    let event_from_ludo = feign_win(@player_0, @player_1, @player_2, @player_3, @context);

    let winner_amount = event_from_ludo.data.at(0);
    assert_eq!(*winner_amount, 0);
}

#[test]
#[should_panic(expected: 'SESSION NOT PLAYING')]
fn should_panic_when_player_plays_after_game_ends() {
    let player_0 = PLAYER_0();
    let player_1 = PLAYER_1();
    let player_2 = PLAYER_2();
    let player_3 = PLAYER_3();

    // given a new game
    let (context, _) = setup_game_4_players(ZERO_TOKEN(), 0);

    let _ = feign_win(@player_0, @player_1, @player_2, @player_3, @context);
    // Here, the game has ended.
    println!("-- Playing move for player 1 pin 3");
    let ludo_move_3 = LudoMove { token_id: 3 };
    // Roll any number. Let's say 2.
    let mut ver_rand_num_array_ref = generate_verifiable_random_numbers(1, 1, 0, 2);
    let (_, _, _, _) = player_move(
        context, @ludo_move_3, player_1, ver_rand_num_array_ref.pop_front().unwrap(),
    );
}

#[test]
fn should_distribute_eth_prize_to_winner() {
    // given a new game
    let eth_contract_address = ETH_TOKEN_ADDRESS();
    let play_amount = 100000;
    let (context, _) = setup_game_4_players(eth_contract_address, play_amount);

    let player_0 = PLAYER_0();
    let player_1 = PLAYER_1();
    let player_2 = PLAYER_2();
    let player_3 = PLAYER_3();

    let erc20_dispatcher = IERC20Dispatcher { contract_address: eth_contract_address };

    let event_from_ludo = feign_win(@player_0, @player_1, @player_2, @player_3, @context);

    let total_fee: felt252 = 400; // Improve this hadcoded value
    let num_players: felt252 = 4;
    let expected_winner_amount: felt252 = play_amount.try_into().unwrap() * num_players - total_fee;
    let winner_amount = event_from_ludo.data.at(0);
    println!("-- Winning amount: {:?}", *winner_amount);
    assert_eq!(*winner_amount, expected_winner_amount);
    let player_0_balance = erc20_dispatcher.balance_of(player_0);
    println!("-- Player 0 balance after winning: {:?}", player_0_balance);
}

#[test]
#[should_panic]
fn should_panic_when_player_tries_to_join_session_twice() {
    // given a new game
    let (context, _) = setup_game_new(ZERO_TOKEN(), 0);
    let player_0 = PLAYER_0();

    // when player 0 tries to join the session twice
    cheat_caller_address(context.ludo_contract, player_0, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);
    cheat_caller_address(context.ludo_contract, player_0, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);
}

#[test]
#[should_panic(expected: 'NOT PLAYER TURN')]
fn should_panic_when_player_tries_to_play_out_of_turn() {
    // roll a pla
    let (context, _) = setup_game_4_players(ZERO_TOKEN(), 0);
    let player_0 = PLAYER_0();
    let player_1 = PLAYER_1();
    let ludo_move = LudoMove { token_id: 0 };
    let mut ver_rand_num_array_ref = generate_verifiable_random_numbers(2, 2, 6, 2);

    println!("-- Playing move for player 0");
    let (_, _, _, _) = player_move(
        context, @ludo_move, player_0, ver_rand_num_array_ref.pop_front().unwrap(),
    );

    println!("-- Playing move for player 1");
    let (_, _, _, _) = player_move(
        context, @ludo_move, player_1, ver_rand_num_array_ref.pop_front().unwrap(),
    );

    // Player 1 tries to roll again
    let mut ver_rand_num_array_ref = generate_verifiable_random_numbers(1, 1, 0, 1);
    let (_, _, _, _) = player_move(
        context, @ludo_move, player_1, ver_rand_num_array_ref.pop_front().unwrap(),
    );
}

// Should panic when player tries to join another session while in session
#[test]
#[should_panic(expected: 'PLAYER HAS SESSION')]
fn should_panic_when_player_tries_to_join_another_session_while_locked_in_session() {
    // given a new game
    let (context, _) = setup_game_new(ZERO_TOKEN(), 0);
    let player_1 = PLAYER_1();
    let some_player: ContractAddress = 'SOME_PLAYER'.try_into().unwrap();
    println!("First session id: {:?}", context.session_id);

    // when player 1 joins the session
    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);
    let (session_data, _) = context.ludo_dispatcher.get_session_status(context.session_id);
    let player_count = session_data.player_count;
    let status = session_data.status;
    let expected_player_count = 2;
    let expected_status = 1; // waiting for players
    assert_eq!(player_count, expected_player_count);
    assert_eq!(status, expected_status);

    // when player 0 tries to join another session that some player created.
    cheat_caller_address(context.ludo_contract, some_player, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.create_session(ZERO_TOKEN(), 0);
    println!("Second session id: {:?}", context.session_id);
    cheat_caller_address(context.ludo_contract, player_1, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);
}

#[test]
#[should_panic(expected: 'SESSION NOT PLAYING')]
fn should_panic_when_player_plays_when_session_is_not_playing_yet() {
    // given a new game
    let (context, _) = setup_game_new(ZERO_TOKEN(), 0);
    let player_0 = PLAYER_0();

    // when player 0 tries to play before session starts
    let ludo_move = LudoMove { token_id: 0 };
    let mut ver_rand_num_array_ref = generate_verifiable_random_numbers(1, 1, 6, 1);
    let _ = player_move(context, @ludo_move, player_0, ver_rand_num_array_ref.pop_front().unwrap());
}

#[test]
#[should_panic(expected: 'SESSION NOT WAITING')]
fn should_panic_when_a_player_joins_a_full_session() {
    // given a new game
    let (context, _) = setup_game_4_players(ZERO_TOKEN(), 0);

    // when player 4 tries to join the session
    let player_4: ContractAddress = 'PLAYER_4'.try_into().unwrap();
    cheat_caller_address(context.ludo_contract, player_4, CheatSpan::TargetCalls(1));
    context.marquis_game_dispatcher.join_session(context.session_id);
}

#[test]
#[should_panic]
fn should_panic_the_contract_upgrade_when_caller_is_not_owner() {
    let NOT_OWNER = PLAYER_0();
    upgrade_contract(NOT_OWNER);
}

#[test]
fn should_allow_contract_upgrade_when_caller_is_owner() {
    upgrade_contract(OWNER());
}

#[test]
#[should_panic(expected: 'UNSUPPORTED TOKEN')]
fn should_panic_when_game_is_initialized_with_unsupported_token() {
    let ludo_contract = deploy_ludo_contract();
    let marquis_game_dispatcher = IMarquisGameDispatcher { contract_address: ludo_contract };
    let token_address = USDC_TOKEN_ADDRESS();
    let player_0 = PLAYER_0();
    let amount: u256 = 100;

    cheat_caller_address(ludo_contract, player_0, CheatSpan::TargetCalls(1));
    let _ = marquis_game_dispatcher.create_session(token_address, amount);
}

#[test]
#[should_panic(expected: 'Token already supported')]
fn should_panic_when_supported_token_is_added_more_than_once() {
    let marquis_contract = deploy_marquis_contract();
    let marquis_dispatcher = IMarquisCoreDispatcher { contract_address: marquis_contract };
    let token_address = USDC_TOKEN_ADDRESS();
    let fee = 1;
    let supported_token = SupportedToken { token_address, fee };
    cheat_caller_address(marquis_contract, OWNER(), CheatSpan::TargetCalls(2));
    marquis_dispatcher.add_supported_token(supported_token);
    let supported_token = SupportedToken { token_address, fee };
    marquis_dispatcher.add_supported_token(supported_token)
}
