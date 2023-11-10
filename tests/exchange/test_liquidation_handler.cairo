use snforge_std::{
    declare, start_prank, stop_prank, start_roll, ContractClassTrait, ContractClass, PrintTrait
};

use satoru::exchange::liquidation_handler::{
    LiquidationHandler, ILiquidationHandlerDispatcher, ILiquidationHandler,
    ILiquidationHandlerDispatcherTrait
};
use starknet::{
    ContractAddress, contract_address_const, contract_address_to_felt252, ClassHash,
    Felt252TryIntoContractAddress
};
use satoru::position::position_utils::get_position_key;
use satoru::mock::referral_storage;
use traits::Default;
use satoru::oracle::oracle_utils::SetPricesParams;
use satoru::role::role_store::{IRoleStoreDispatcher, IRoleStoreDispatcherTrait};
use satoru::role::role;
use satoru::role::role_module::{IRoleModuleDispatcher, IRoleModuleDispatcherTrait};
use satoru::order::order::{Order, OrderType, OrderTrait, DecreasePositionSwapType};
use satoru::utils::span32::{Span32, Array32Trait};
use satoru::position::position::Position;
use satoru::liquidation::liquidation_utils::create_liquidation_order;
use satoru::exchange::base_order_handler::{IBaseOrderHandler, BaseOrderHandler};
use satoru::exchange::base_order_handler::BaseOrderHandler::{
    event_emitter::InternalContractMemberStateTrait, data_store::InternalContractMemberStateImpl
};
use satoru::event::event_emitter::{IEventEmitterDispatcher};
use satoru::data::{data_store::{IDataStoreDispatcher, IDataStoreDispatcherTrait}, keys};
use satoru::oracle::oracle::{Oracle, IOracleDispatcher, IOracleDispatcherTrait};
use satoru::utils::precision;
use satoru::price::price::Price;
use satoru::oracle::oracle_store::{IOracleStoreDispatcher, IOracleStoreDispatcherTrait};
use satoru::oracle::{interfaces::account::{IAccount, IAccountDispatcher, IAccountDispatcherTrait}};
use satoru::market::market::{Market};

const max_u128: u128 = 340282366920938463463374607431768211455;

#[test]
#[should_panic(expected: ('unauthorized_access',))]
fn given_unauthorized_access_when_create_execute_liquidation_then_fails() {
    // Setup

    let collateral_token: ContractAddress = contract_address_const::<1>();
    let (
        data_store,
        liquidation_keeper,
        liquidation_handler_address,
        liquidation_handler_dispatcher,
        _,
        role_store,
        _,
        _,
        _
    ) =
        _setup();
    let oracle_params = Default::default();

    // Check that the test function panics when the caller doesn't have the LIQUIDATION_KEEPER role
    liquidation_handler_dispatcher
        .execute_liquidation(
            account: contract_address_const::<'account'>(),
            market: contract_address_const::<'market'>(),
            collateral_token: collateral_token,
            is_long: true,
            oracle_params: oracle_params
        );
}

#[test]
#[should_panic(expected: ('empty price feed', 'ETH'))]
fn given_empty_price_feed_multiplier_when_create_execute_liquidation_then_fails() {
    // Setup
    let collateral_token: ContractAddress = contract_address_const::<1>();
    let (
        data_store,
        liquidation_keeper,
        liquidation_handler_address,
        liquidation_handler_dispatcher,
        _,
        role_store,
        _,
        _,
        _
    ) =
        _setup();

    start_prank(role_store.contract_address, admin());
    role_store.grant_role(liquidation_keeper, role::LIQUIDATION_KEEPER);
    stop_prank(role_store.contract_address);
    start_prank(liquidation_handler_address, liquidation_keeper);

    let token1 = contract_address_const::<'ETH'>();
    let price_feed_tokens1 = contract_address_const::<'price_feed_tokens'>();

    let mut  oracle_params = mock_set_prices_params(token1);
    oracle_params.price_feed_tokens= array![token1];
    // Check that execute_liquidation calls 'with_oracle_prices_before' and fails

    liquidation_handler_dispatcher
        .execute_liquidation(
            account: contract_address_const::<'account'>(),
            market: contract_address_const::<'market'>(),
            collateral_token: collateral_token,
            is_long: true,
            oracle_params: oracle_params
        );
}

#[test]
fn given_normal_conditions_when_create_execute_liquidation_then_works() {
    // Setup

    let collateral_token: ContractAddress = contract_address_const::<'USDC'>();
    let (
        data_store,
        liquidation_keeper,
        liquidation_handler_address,
        liquidation_handler_dispatcher,
        event_emitter,
        role_store,
        oracle,
        signer1,
        signer2
    ) =
        _setup();
    let account =contract_address_const::<'account'>();
    
    // Grant LIQUIDATION_KEEPER role
    start_prank(role_store.contract_address, admin());
    role_store.grant_role(liquidation_keeper, role::LIQUIDATION_KEEPER);
    stop_prank(role_store.contract_address);
    start_prank(liquidation_handler_address, liquidation_keeper);

    let token1 = contract_address_const::<'ETH'>();
    let token2 = contract_address_const::<'BTC'>();

    // Use mock account to mattch keys                                                          
    signer1.change_owner(1221698997303567203808303576674742997327105320284925779268978961645745386877, 0, 0);
    signer2.change_owner(1221698997303567203808303576674742997327105320284925779268978961645745386877, 0, 0);

    data_store.set_token_id(token1, 1);
    data_store.set_token_id(token2, 2);

    // Set price feed multiplier
    data_store.set_u128(keys::price_feed_multiplier_key(token1), precision::FLOAT_PRECISION);
    data_store.set_u128(keys::price_feed_multiplier_key(token2), precision::FLOAT_PRECISION);
    data_store.set_u128(keys::max_oracle_ref_price_deviation_factor(),max_u128 );

    // 
    let mut market = Market {
        market_token: contract_address_const::<'market'>(),
        index_token:  collateral_token,
        long_token:  token1,
        short_token:  token1,
    };
    data_store.set_market(market.market_token, 0, market);

    // Get position key 
    'setpos-------'.print();

    let pos_key=get_position_key(account, market.market_token, collateral_token, true);
    let mut position:Position= Default::default();
    position.account=account;
    position.size_in_usd=precision::FLOAT_PRECISION_SQRT;
    position.collateral_token=collateral_token;
    position.is_long=true;
    data_store.set_position(pos_key, position);

    let oracle_params = mock_set_prices_params(token1);

    liquidation_handler_dispatcher
        .execute_liquidation(
            account:account,
            market: market.market_token,
            collateral_token: collateral_token,
            is_long: true,
            oracle_params: oracle_params
        );
    'execute_liquidation2'.print();
}


// *********************************************************************************************
// *                              SETUP                                                        *
// *********************************************************************************************

fn mock_set_prices_params(token: ContractAddress) -> SetPricesParams {
    SetPricesParams {
        signer_info: 1,
        tokens: array![token],
        compacted_min_oracle_block_numbers: array![10,],
        compacted_max_oracle_block_numbers: array![20],
        compacted_oracle_timestamps: array![1000,],
        compacted_decimals: array![18],
        compacted_min_prices: array![1700,],
        compacted_min_prices_indexes: array![0,],
        compacted_max_prices: array![1750],
        compacted_max_prices_indexes: array![0,],
        signatures: array![array!['signature1', 'signature2'].span()],
        price_feed_tokens:  Default::default()
    }
}


fn admin() -> ContractAddress {
    contract_address_const::<'caller'>()
}


fn deploy_data_store(role_store_address: ContractAddress) -> ContractAddress {
    let contract = declare('DataStore');

    let deployed_contract_address = contract_address_const::<'data_store'>();
    start_prank(deployed_contract_address, admin());
    let constructor_calldata = array![role_store_address.into()];
    contract.deploy_at(@constructor_calldata, deployed_contract_address).unwrap()
}


fn deploy_event_emitter() -> ContractAddress {
    let contract = declare('EventEmitter');

    let deployed_contract_address = contract_address_const::<'event_emitter'>();
    start_prank(deployed_contract_address, admin());
    contract.deploy_at(@array![], deployed_contract_address).unwrap()
}

fn deploy_order_vault(
    data_store_address: ContractAddress, role_store_address: ContractAddress
) -> ContractAddress {
    let contract = declare('OrderVault');

    let deployed_contract_address = contract_address_const::<'order_vault'>();
    start_prank(deployed_contract_address, admin());
    contract
        .deploy_at(
            @array![data_store_address.into(), role_store_address.into()], deployed_contract_address
        )
        .unwrap()
}

fn deploy_liquidation_handler(
    role_store_address: ContractAddress,
    data_store_address: ContractAddress,
    event_emitter_address: ContractAddress,
    order_vault_address: ContractAddress,
    swap_handler_address: ContractAddress,
    oracle_address: ContractAddress
) -> ContractAddress {
    let contract = declare('LiquidationHandler');

    let deployed_contract_address = contract_address_const::<'liquidation_handler'>();
    start_prank(deployed_contract_address, admin());
    contract
        .deploy_at(
            @array![
                data_store_address.into(),
                role_store_address.into(),
                event_emitter_address.into(),
                order_vault_address.into(),
                oracle_address.into(),
                swap_handler_address.into(),
                Default::default()
            ],
            deployed_contract_address
        )
        .unwrap()
}

fn deploy_oracle(
    role_store_address: ContractAddress,
    oracle_store_address: ContractAddress,
    pragma_address: ContractAddress
) -> ContractAddress {
    let contract = declare('Oracle');

    let deployed_contract_address = contract_address_const::<'oracle'>();
    start_prank(deployed_contract_address, admin());
    contract
        .deploy_at(
            @array![role_store_address.into(), oracle_store_address.into(), pragma_address.into()],
            deployed_contract_address
        )
        .unwrap()
}

fn deploy_swap_handler(
    role_store_address: ContractAddress, data_store_address: ContractAddress
) -> ContractAddress {
    let contract = declare('SwapHandler');

    let deployed_contract_address = contract_address_const::<'swap_handler'>();
    start_prank(deployed_contract_address, admin());
    contract.deploy_at(@array![role_store_address.into()], deployed_contract_address).unwrap()
}

fn deploy_referral_storage() -> ContractAddress {
    let contract = declare('ReferralStorage');

    let deployed_contract_address = contract_address_const::<'referral_storage'>();
    start_prank(deployed_contract_address, admin());
    contract.deploy_at(@array![], deployed_contract_address).unwrap()
}

fn deploy_oracle_store(
    role_store_address: ContractAddress, event_emitter_address: ContractAddress,
) -> ContractAddress {
    let contract = declare('OracleStore');

    let deployed_contract_address = contract_address_const::<'oracle_store'>();
    start_prank(deployed_contract_address, admin());
    contract
        .deploy_at(
            @array![role_store_address.into(), event_emitter_address.into()],
            deployed_contract_address
        )
        .unwrap()
}


fn deploy_role_store() -> ContractAddress {
    let contract = declare('RoleStore');
    let deployed_contract_address: ContractAddress = contract_address_const::<'role_store'>();
    start_prank(deployed_contract_address, admin());
    contract.deploy_at(@array![], deployed_contract_address).unwrap()
}

fn deploy_price_feed() -> ContractAddress {
    let contract = declare('PriceFeed');
    let deployed_contract_address: ContractAddress = contract_address_const::<'price_feed'>();
    start_prank(deployed_contract_address, admin());
    contract.deploy_at(@array![], deployed_contract_address).unwrap()
}

fn deploy_signers(
    signer1: ContractAddress, signer2: ContractAddress
) -> (ContractAddress, ContractAddress) {
    let contract = declare('MockAccount');
    (
        contract.deploy_at(@array![], signer1).unwrap(),
        contract.deploy_at(@array![], signer2).unwrap()
    )
}


fn _setup() -> (
    IDataStoreDispatcher,
    ContractAddress,
    ContractAddress,
    ILiquidationHandlerDispatcher,
    IEventEmitterDispatcher,
    IRoleStoreDispatcher,
    IOracleDispatcher,
    IAccountDispatcher,
    IAccountDispatcher
) {
    let liquidation_keeper: ContractAddress = 0x2233.try_into().unwrap();
    let role_store_address = deploy_role_store();
    let role_store = IRoleStoreDispatcher { contract_address: role_store_address };

    let data_store_address = deploy_data_store(role_store_address);
    let data_store = IDataStoreDispatcher { contract_address: data_store_address };
    let event_emitter_address = deploy_event_emitter();
    let event_emitter = IEventEmitterDispatcher { contract_address: event_emitter_address };
    let order_vault_address = deploy_order_vault(data_store_address, role_store_address);
    let swap_handler_address = deploy_swap_handler(role_store_address, data_store_address);
    let oracle_store_address = deploy_oracle_store(role_store_address, event_emitter_address);
    let price_feed = deploy_price_feed();
    let oracle_address = deploy_oracle(role_store_address, oracle_store_address, price_feed);

    let liquidation_handler_address = deploy_liquidation_handler(
        role_store_address,
        data_store_address,
        event_emitter_address,
        order_vault_address,
        swap_handler_address,
        oracle_address
    );
    let liquidation_handler_dispatcher = ILiquidationHandlerDispatcher {
        contract_address: liquidation_handler_address
    };

    let oracle_store = IOracleStoreDispatcher { contract_address: oracle_store_address };

    let (signer1, signer2) = deploy_signers(
        contract_address_const::<'signer1'>(), contract_address_const::<'signer2'>()
    );
    start_prank(oracle_store_address, admin());
    oracle_store.add_signer(signer1);
    oracle_store.add_signer(signer2);
    stop_prank(oracle_store_address);

    start_prank(role_store.contract_address, admin());
    role_store.grant_role(liquidation_handler_address, role::CONTROLLER);
    role_store.grant_role( admin(), role::MARKET_KEEPER);
    role_store.grant_role(admin(), role::CONTROLLER);
    stop_prank(role_store.contract_address);

    start_prank(data_store_address, admin());

    (
        data_store,
        liquidation_keeper,
        liquidation_handler_address,
        liquidation_handler_dispatcher,
        event_emitter,
        role_store,
        IOracleDispatcher { contract_address: oracle_address },
        IAccountDispatcher { contract_address: signer1 },
        IAccountDispatcher { contract_address: signer2 },
    )
}
