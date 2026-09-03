// This will error if anything drifts in the type definitions, so it is a test of the types themselves.

import Ledger from "../index";

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2 ? true : false;
type Expect<T extends true> = T;

interface Profile {
	Gold: number;
	Items: { [item: string]: boolean };
}

interface Ops {
	Buy: { Item: string };
	Sell: { Item: string };
	AddGold: { Amount: number };
	Ping: {};
}

declare const player: Player;
declare const DataStoreService: DataStoreService;

export type FiveEntries = Expect<Equal<keyof typeof Ledger, "Reason" | "New" | "NewTyped" | "Sweep" | "CloseAll">>;
export type ReasonNamesEveryReason = Expect<Equal<keyof typeof Ledger.Reason, Ledger.Reason>>;
export type ReasonIsItself = Expect<Equal<(typeof Ledger.Reason)["Busy"], "Busy">>;

export type StoresShareTheirMethods = Expect<Equal<keyof Ledger.Store<Profile>, keyof Ledger.TypedStore<Profile, Ops>>>;
export type SessionsShareTheirMethods = Expect<Equal<keyof Ledger.Session<Profile>, keyof Ledger.TypedSession<Profile, Ops>>>;
export type ConfigsShareTheirFields = Expect<Equal<keyof Ledger.Config<Profile>, keyof Ledger.TypedConfig<Profile, Ops>>>;

export type NewIsDotCalled = Expect<Equal<ThisParameterType<typeof Ledger.New>, void>>;
export type CloseAllIsDotCalled = Expect<Equal<ThisParameterType<typeof Ledger.CloseAll>, void>>;
export type ReducerIsDotCalled = Expect<Equal<ThisParameterType<Ledger.Reducer<Profile>>, void>>;
export type HookOpenIsDotCalled = Expect<Equal<ThisParameterType<Ledger.Hook["Open"]>, void>>;
export type PeekIsColonCalled = Expect<Equal<ThisParameterType<Ledger.Store<Profile>["Peek"]>, unknown>>;
export type ApplyIsColonCalled = Expect<Equal<ThisParameterType<Ledger.Session<Profile>["Apply"]>, unknown>>;
export type WaitIsColonCalled = Expect<Equal<ThisParameterType<Ledger.Future<[boolean]>["Wait"]>, unknown>>;

export type ReadAnswersTheState = Expect<Equal<ReturnType<Ledger.Store<Profile>["Read"]>, Profile | undefined>>;
export type PeekAnswersAValueAndAReason = Expect<Equal<ReturnType<Ledger.Store<Profile>["Peek"]>, Ledger.Future<[Profile | undefined, Ledger.Reason | undefined]>>>;
export type NumberKeysNamesTheNumbers = Expect<Equal<Ledger.NumberKeys<Profile>, "Gold">>;
export type TotalTakesAnOptionalAge = Expect<Equal<Parameters<Ledger.Store<Profile>["Total"]>, [name: string, field: "Gold", maxAge?: number | undefined]>>;
export type OpenOpIsTheDefault = Expect<Equal<Ledger.Op, Ledger.OpenOp>>;
export type OpOfNamesOneKind = Expect<Equal<Ledger.OpOf<Ops, "Buy">["Kind"], "Buy">>;
export type OpUnionHasEveryKind = Expect<Equal<Ledger.Op<Ops>["Kind"], "Buy" | "Sell" | "AddGold" | "Ping">>;
export type AStoreIsALegStore = Expect<Ledger.Store<Profile> extends Ledger.TxLeg["Store"] ? true : false>;
export type ATypedStoreIsALegStore = Expect<Ledger.TypedStore<Profile, Ops> extends Ledger.TxLeg["Store"] ? true : false>;

function Reducer(this: void, state: Profile, op: Ledger.Op<Ops>): Profile | undefined {
	if (op.Kind === "Buy") {
		const item: string = op.Item;
		if (state.Items[item] === true) {
			return undefined;
		}
		return { Gold: state.Gold - 1, Items: { ...state.Items, [item]: true } };
	}
	if (op.Kind === "AddGold") {
		const amount: number = op.Amount;
		return { ...state, Gold: state.Gold + amount };
	}
	return undefined;
}

function OpenReducer(this: void, state: Profile, op: Ledger.Op): Profile | undefined {
	if (op.Kind === "AddGold") {
		const amount = op["Amount"];
		if (!typeIs(amount, "number")) {
			return undefined;
		}
		return { ...state, Gold: state.Gold + amount };
	}
	return undefined;
}

export function Positives(): void {
	const shop: Ledger.TypedStore<Profile, Ops> = Ledger.NewTyped<Profile, Ops>({
		Name: "Shop",
		Default: { Gold: 100, Items: {} },
		Reducer,
		Balance: "Gold",
		Mock: { Players: 10, CCU: 1000 },
	});

	const bank = Ledger.New({
		Name: "Bank",
		Default: { Gold: 0, Items: {} },
		Reducer: OpenReducer,
		Keys: "Player",
		OnLoadFailed: (who, why) => why === Ledger.Reason.Busy && who.Name !== "",
		Migrations: [(state) => (typeIs(state, "table") ? state : {}), { Apply: (state) => (typeIs(state, "table") ? state : {}), Compatible: true }],
	});
	const inferredFromTheReducer: Expect<Equal<typeof bank, Ledger.Store<Profile>>> = true;
	void inferredFromTheReducer;

	const named = Ledger.New<Profile>({ Name: "Named", Default: { Gold: 0, Items: {} }, Reducer: (state) => state });
	void named;

	const fresh: Profile = { Gold: 0, Items: {} };
	const fromDefault = Ledger.New({ Name: "FromDefault", Default: fresh, Reducer: (state) => state });
	const inferredFromTheDefault: Expect<Equal<typeof fromDefault, Ledger.Store<Profile>>> = true;
	void inferredFromTheDefault;

	interface Legacy {
		Coins?: number;
	}
	const migrated = Ledger.New<Profile>({
		Name: "Migrated",
		Default: fresh,
		Reducer: (state) => state,
		Migrations: [(state: Legacy) => ({ Gold: state.Coins ?? 0, Items: {} }), { Apply: (state: Legacy) => ({ ...state, Items: {} }), Compatible: true }],
	});
	void migrated;

	const hook: Ledger.Hook = {
		Open: (name) => DataStoreService.GetDataStore(name),
		Budget: (kind) => DataStoreService.GetRequestBudgetForRequestType(kind),
	};
	const hooked = Ledger.New<Profile>({ Name: "Hooked", Default: { Gold: 0, Items: {} }, Reducer: OpenReducer, Hook: hook });
	void hooked;

	const session = shop.Expect(player);
	const [bought, why] = session.Apply("Buy", { Item: "Sword" });
	const sure: boolean = bought;
	const reason: Ledger.Reason | undefined = why;
	void sure;
	void reason;

	session.Apply("Ping", {});
	session.Apply("AddGold", { Amount: 5, Once: "gift:1" });
	session.Commit("Sell", { Item: "Sword" }).Wait();
	session.CommitOp({ Id: "op-1", Kind: "Buy", Item: "Shield", Once: "receipt:1" });
	shop.Edit(1, "AddGold", { Amount: 5 }).Wait();
	shop.Reserve(1, "Gold", 5, "cart:1", { Hold: 60 });
	shop.Confirm(1, "cart:1", "Buy", { Item: "Sword" });
	shop.Release(1, "cart:1");
	shop.Transfer(1, 2, 5, "tip:1", "Gold");
	const [holding, holdingWhy] = shop.Holds(1, "Gold").Wait();
	const heldUnits: number | undefined = holding;
	const heldWhy: Ledger.Reason | undefined = holdingWhy;
	void heldUnits;
	void heldWhy;

	const open = bank.Expect(player);
	open.Apply("AddGold", { Amount: 5 });
	open.Apply("Ping");
	open.Commit("ProductGrant", { ProductId: 1, Once: "receipt:1" });
	open.CommitOp({ Id: "op-2", Kind: "AddGold", Amount: 5 });
	bank.Edit("42", "AddGold", { Amount: 5 });
	bank.Confirm("42", "cart:2", "AddGold", { Amount: 1 });
	bank.Confirm("42", "cart:3", "Ping");

	const [state, peeked] = bank.Peek(1).Wait();
	const held: Profile | undefined = state;
	const peekedWhy: Ledger.Reason | undefined = peeked;
	void held;
	void peekedWhy;

	const [timed, timedWhy] = bank.Peek(1).Wait(5);
	const maybe: Profile | undefined = timed;
	const maybeWhy: Ledger.Reason | undefined = timedWhy;
	void maybe;
	void maybeWhy;

	const [landed] = open.Flush().Wait();
	const landedForSure: boolean = landed;
	void landedForSure;

	const [landedOrNot] = open.Flush().Wait(5);
	const landedMaybe: boolean | undefined = landedOrNot;
	void landedMaybe;

	const gold = session
		.Observe()
		.Map((next) => next.Gold)
		.Changed()
		.Subscribe((amount) => {
			const n: number = amount;
			void n;
		});
	gold.Disconnect();
	bank.Stale().Subscribe((key) => {
		const k: string = key;
		void k;
	});

	bank.Tx("trade:1", [
		{ UserId: 1, Kind: "Give", Fields: { Item: "Sword" } },
		{ Store: shop, UserId: 2, Kind: "AddGold", Fields: { Amount: 5 } },
	]);

	const applied: boolean = session.DidApply("receipt:1");
	void applied;
	const [record] = shop.Inspect(1).Wait();
	const ops: ReadonlyArray<Ledger.OpenOp> | undefined = record?.Ops;
	void ops;

	Ledger.Sweep();
	Ledger.CloseAll();
}

export function Negatives(): void {
	const shop = Ledger.NewTyped<Profile, Ops>({ Name: "Shop", Default: { Gold: 100, Items: {} }, Reducer });
	const session = shop.Expect(player);
	const bank = Ledger.New<Profile>({ Name: "Bank", Default: { Gold: 0, Items: {} }, Reducer: OpenReducer });
	const open = bank.Expect(player);

	// @ts-expect-error no kind by that name
	session.Apply("Byu", { Item: "Sword" });
	// @ts-expect-error Item is a string
	session.Apply("Buy", { Item: 42 });
	// @ts-expect-error no field by that name
	session.Apply("Buy", { Itme: "Sword" });
	// @ts-expect-error those are AddGold's fields
	session.Apply("Buy", { Amount: 5 });
	// @ts-expect-error Amount is a number
	shop.Edit(1, "AddGold", { Amount: "5" });
	// @ts-expect-error a kind takes its fields whether or not it has any
	session.Apply("Ping");
	// @ts-expect-error Id belongs to Ledger
	session.Apply("Buy", { Item: "Sword", Id: "mine" });
	// @ts-expect-error Once is a string
	session.Apply("Buy", { Item: "Sword", Once: 5 });
	// @ts-expect-error a committed op names a kind the store has
	session.CommitOp({ Id: "op-1", Kind: "Byu", Item: "Sword" });

	// @ts-expect-error Kind belongs to Ledger on an open store too
	open.Apply("AddGold", { Kind: "Sell" });
	// @ts-expect-error OnceAt belongs to Ledger
	open.Apply("AddGold", { Amount: 5, OnceAt: 1 });

	// @ts-expect-error Items is not a number field
	shop.Reserve(1, "Items", 5, "cart:1");
	// @ts-expect-error a hold stays on its key, To is gone
	shop.Reserve(1, "Gold", 5, "cart:1", { To: 2 });
	// @ts-expect-error Confirm names a kind the store has
	shop.Confirm(1, "cart:1", "Byu", { Item: "Sword" });
	// @ts-expect-error a confirm takes the kind's own fields
	shop.Confirm(1, "cart:1", "Buy", { Amount: 5 });
	// @ts-expect-error Items is not a number field
	shop.Transfer(1, 2, 5, "tip:1", "Items");
	// @ts-expect-error Items is not a number field
	shop.Holds(1, "Items");
	// @ts-expect-error Balance names a number field
	Ledger.New<Profile>({ Name: "Wrong", Default: { Gold: 0, Items: {} }, Reducer: OpenReducer, Balance: "Items" });
	// @ts-expect-error the Default has to be the reducer's state
	Ledger.New({ Name: "Wrong", Default: { Gold: "0", Items: {} }, Reducer: OpenReducer });
	// @ts-expect-error a key mode is Player or String
	Ledger.New<Profile>({ Name: "Wrong", Default: { Gold: 0, Items: {} }, Reducer: OpenReducer, Keys: "Players" });
	// @ts-expect-error a migration step gives back a state, not a number
	Ledger.New<Profile>({ Name: "Wrong", Default: { Gold: 0, Items: {} }, Reducer: OpenReducer, Migrations: [() => 5] });
	// @ts-expect-error a kind has to name its fields as an object
	Ledger.NewTyped<Profile, { Buy: string }>({ Name: "Wrong", Default: { Gold: 0, Items: {} }, Reducer: (state) => state });
	// @ts-expect-error Mock takes Players, CCU and Throttled
	Ledger.New<Profile>({ Name: "Wrong", Default: { Gold: 0, Items: {} }, Reducer: OpenReducer, Mock: { Player: 1 } });

	// @ts-expect-error Read takes a Player, not a key
	bank.Read(1);
	// @ts-expect-error no reason by that name
	void Ledger.Reason.Bussy;
	// @ts-expect-error a timed wait can answer nothing
	const sure: LuaTuple<[boolean, Ledger.Reason | undefined]> = open.Flush().Wait(5);
	void sure;

	function Mutating(this: void, state: Profile, op: Ledger.Op<Ops>): Profile | undefined {
		if (op.Kind === "Buy") {
			// @ts-expect-error AddGold's field, not Buy's
			void op.Amount;
			// @ts-expect-error an op is read only
			op.Item = "Shield";
		}
		return state;
	}
	void Mutating;
}
