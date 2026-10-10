declare namespace Ledger {
	type Reason =
		| "Refused"
		| "Spent"
		| "Busy"
		| "Full"
		| "Invalid"
		| "Behind"
		| "Unreadable"
		| "Closed"
		| "Backlog"
		| "Expired"
		| "NoRoom"
		| "Missing"
		| "Short"
		| "SoldOut"
		| "Unresolved";

	type ShortReason = "Free" | "Held" | "Holds" | "Gone";

	type KeyLike = Player | number | string;

	type KeysMode = "Player" | "String";

	type OpMap<O> = { readonly [K in keyof O]: object };

	type Frozen<T> = T extends (...args: never[]) => unknown
		? T
		: T extends object
			? { readonly [K in keyof T]: Frozen<T[K]> }
			: T;

	type OpOf<O, K extends keyof O & string> = { readonly Kind: K } & Readonly<O[K]>;

	type Op<O = never> = [O] extends [never]
		? { readonly Kind: string; readonly [field: string]: unknown }
		: { [K in keyof O & string]: OpOf<O, K> }[keyof O & string];

	type Reducer<D, O = never> = (this: void, state: Frozen<D>, op: Op<O>) => D | undefined;

	type ResultSchema<D> = (this: void, state: Frozen<D>) => LuaTuple<[boolean, string | undefined]>;

	type LoadFailedHandler = (this: void, player: Player, reason: Reason) => void;

	interface OpId {
		readonly Name: { readonly Kind: string };
	}

	type Name = string | OpId;

	interface Identity {
		readonly Server: number;
		readonly Counter: number;
	}

	type Amount =
		| { readonly Kind: "Default"; readonly IsNegative?: boolean; readonly High: number; readonly Low: number }
		| { readonly Kind: "Encoded"; readonly Text: string };

	interface Arithmetic<T = unknown> {
		readonly Zero: T;
		readonly Add: (this: void, left: T, right: T) => T;
		readonly Subtract: (this: void, left: T, right: T) => T;
		readonly Compare: (this: void, left: T, right: T) => number;
		readonly IsValid: (this: void, value: unknown) => boolean;
		readonly Encode: (this: void, value: T) => string;
		readonly Decode: (this: void, text: string) => T | undefined;
		readonly Max?: T;
	}

	interface BalanceKindLimits<T = unknown> {
		readonly Kind: string;
		readonly Min?: NoInfer<T>;
		readonly Max?: NoInfer<T>;
	}

	interface BalanceField<T = unknown> {
		readonly Credit?: string | ReadonlyArray<string | BalanceKindLimits<T>>;
		readonly Debit?: string | ReadonlyArray<string | BalanceKindLimits<T>>;
		readonly Min?: NoInfer<T>;
		readonly Max?: NoInfer<T>;
		readonly Arithmetic?: Arithmetic<T>;
	}

	interface Migration {
		readonly Run: (this: void, state: unknown) => unknown;
		readonly IsBreaking?: boolean;
		readonly Fields?: ReadonlyArray<string>;
	}

	interface Windows {
		readonly [kind: string]: { readonly Timed?: number; readonly Untimed?: number };
	}

	interface TotalDeclaration {
		readonly Shards?: number;
	}

	interface QuantityDeclaration {
		readonly Parts: number;
		readonly Mode: "Final" | "Open";
		readonly Stock?: number;
		readonly Serials?: { readonly First: number; readonly Count: number };
		readonly Proceeds?: ReadonlyArray<string>;
		readonly Closed?: boolean;
	}

	interface TypedConfig<D, O = never> {
		readonly Name: string;
		readonly Keys: KeysMode;
		readonly Default: D;
		readonly Reducer?: Reducer<D, O>;
		readonly Schema?: ResultSchema<D>;
		readonly Balances?: { readonly [field: string]: BalanceField };
		readonly Migrations?: ReadonlyArray<Migration>;
		readonly MustExist: boolean;
		readonly Erasable: boolean;
		readonly LegLimit?: number;
		readonly OnLoadFailed?: LoadFailedHandler;
		readonly Kick?: boolean;
		readonly KickMessage?: string;
		readonly SaveInterval?: number;
		readonly IdleReadInterval?: number;
		readonly HoldMax?: number;
		readonly OrphanAge?: number;
		readonly Windows?: Windows;
		readonly CutWindow?: number;
		readonly Totals?: { readonly [name: string]: TotalDeclaration };
		readonly Quantities?: { readonly [name: string]: QuantityDeclaration };
		readonly Mock?: object;
	}

	type Config<D> = TypedConfig<D>;

	interface Future<T extends unknown[]> {
		Wait(timeout?: number): LuaTuple<T>;
		Happened(wait?: boolean): boolean;
	}

	interface Connection {
		readonly Connected: boolean;
		Disconnect(): void;
	}

	interface Observer<T> {
		Subscribe(listener: (this: void, value: T) => void): Connection;
		Use<U>(middleware: (this: void, value: T, emit: (this: void, value: U) => void) => void): Observer<U>;
		Map<U>(transform: (this: void, value: T) => U): Observer<U>;
		Filter(predicate: (this: void, value: T) => boolean): Observer<T>;
		Changed(equals?: (this: void, left: T, right: T) => boolean): Observer<T>;
		Destroy(): void;
	}

	interface InfoKey {
		readonly Store: string;
		readonly Key: string | number;
	}

	interface Info<D = unknown> {
		readonly State?: Frozen<D>;
		readonly Identity?: Identity;
		readonly Key?: InfoKey;
		readonly ShortReason?: ShortReason;
		readonly Name?: Name;
		readonly Outcome?: Future<[boolean, Reason | undefined]>;
	}

	interface Applied {
		readonly Name: { readonly Kind: string };
		readonly CallId: number;
		readonly Key: { readonly Store: string; readonly Scope: string; readonly Key: string };
	}

	interface DidApplyInfo {
		readonly IsQueued?: true;
	}

	type CoreName =
		| { readonly Kind: "Game"; readonly Text: string }
		| { readonly Kind: "Drawn"; readonly Server: number; readonly Counter: number };

	type KeyReference =
		| { readonly Kind: "Short"; readonly Key: string }
		| { readonly Kind: "Full"; readonly Store: string; readonly Scope: string; readonly Key: string };

	interface FieldAmount {
		readonly Field: string;
		readonly Amount: Amount;
	}

	interface LossRecords {
		readonly Events: ReadonlyArray<{
			readonly Cause: "Erase" | "Reset";
			readonly Name: CoreName;
			readonly Stamp: number;
			readonly Fields: ReadonlyArray<FieldAmount>;
			readonly Fingerprint?: number;
		}>;
		readonly Returns: ReadonlyArray<{
			readonly Cause: "Returned" | "Orphan";
			readonly Name: CoreName;
			readonly Stamp: number;
			readonly OtherKey: KeyReference;
			readonly Escrow?: FieldAmount;
			readonly Fingerprint?: number;
		}>;
		readonly Slots: ReadonlyArray<{
			readonly Period: number;
			readonly Count: number;
			readonly Sums: ReadonlyArray<FieldAmount>;
		}>;
	}

	interface Cut {
		readonly Name: Name;
		readonly Losses?: LossRecords;
	}

	interface Closed {
		readonly Removed: ReadonlyArray<number>;
		readonly Left: ReadonlyArray<number>;
		readonly Missing: ReadonlyArray<number>;
	}

	type PendingItem =
		| {
				readonly Kind: "Escrow" | "Exclusive";
				readonly Name: CoreName;
				readonly Stamp: number;
				readonly Age: number;
				readonly Attempt: number;
				readonly IsDecided: boolean;
				readonly Decider: { readonly Store: string; readonly Scope: string; readonly Key: string };
		  }
		| {
				readonly Kind: "Pinned";
				readonly Name: CoreName;
				readonly Stamp: number;
				readonly Age: number;
				readonly Attempt: number;
				readonly IsDecided: boolean;
				readonly Legs: ReadonlyArray<{ readonly Store: string; readonly Scope: string; readonly Key: string }>;
		  };

	type PendingItems = ReadonlyArray<PendingItem>;

	interface RecordBook {
		readonly Format: number;
		readonly Level: number;
		readonly Floor: number;
		readonly Writes: number;
		readonly Cuts: number;
		readonly Identity?: Identity;
		readonly Epoch: number;
		readonly Horizon: number;
		readonly CutHorizon: number;
		readonly Work: ReadonlyArray<{
			readonly Kind: "Escrow" | "Exclusive" | "Pinned";
			readonly IsClean: boolean;
			readonly Field?: string;
			readonly Amount?: Amount;
			readonly IsDebit?: boolean;
			readonly Decider?: KeyReference;
		}>;
		readonly Losses: { readonly Events: LossRecords["Events"]; readonly Returns: LossRecords["Returns"] };
		readonly Slots: LossRecords["Slots"];
		readonly Gate?: unknown;
		readonly Timed: ReadonlyArray<unknown>;
		readonly CutNames: ReadonlyArray<unknown>;
		readonly Untimed: ReadonlyArray<unknown>;
	}

	interface Record<D = unknown> {
		readonly Kind: "Kept";
		readonly State: Frozen<D>;
		readonly Book: RecordBook;
		readonly Post?: ReadonlyArray<unknown>;
		readonly Given?: unknown;
	}

	type Fate<O = never> = {
		readonly Applied: Applied;
		readonly Fate:
			| { readonly Kind: "Took" }
			| {
					readonly Kind: "Turned";
					readonly Why: "Refused" | "Full" | "Cut" | "Behind" | "Unreadable";
					readonly State: unknown;
			  }
			| { readonly Kind: "Unknown" };
		readonly Op: Frozen<Op<O>>;
	};

	interface Took {
		readonly Part: number;
		readonly Value?: number;
	}

	interface QuantityTotal {
		readonly Sold: number;
		readonly Free: number;
		readonly Held: number;
	}

	interface HoldHandle {
		readonly Id: CoreName;
		readonly Part: number;
		readonly Count: number;
		readonly End: number;
		readonly Serials?: { readonly First: number; readonly Count: number };
	}

	interface EditOptions {
		readonly MustExist?: boolean;
		readonly Id?: Name;
		readonly IdAt?: number;
	}

	interface CommitOptions {
		readonly Id?: Name;
		readonly IdAt?: number;
	}

	interface BumpOptions {
		readonly Id?: string;
		readonly IdAt?: number;
	}

	interface PeekOptions {
		readonly Fresh: true;
	}

	interface DidApplyOptions {
		readonly IdAt?: number;
		readonly Probe?: boolean;
	}

	interface ResetOptions<D> {
		readonly Id?: OpId;
		readonly IdAt?: number;
		readonly State?: Frozen<D>;
	}

	interface EraseOptions {
		readonly Id?: OpId;
		readonly IdAt?: number;
	}

	interface TxOptions {
		readonly Id?: string;
		readonly IdAt?: number;
	}

	interface LegOptions {
		readonly MustExist?: boolean;
		readonly Slot?: ReadonlyArray<string | number>;
	}

	interface Leg<S = StoreCommon<unknown>> {
		readonly Store: S;
		readonly Key: KeyLike;
		readonly Op: { readonly Kind: string };
		readonly MustExist?: boolean;
		readonly Slot?: ReadonlyArray<string | number>;
	}

	type TxLeg = Leg;

	type TakeLeg = Leg;

	interface KeyOfStore {
		readonly Store: StoreCommon<unknown>;
		readonly Key: KeyLike;
	}

	interface TakeOptions {
		readonly Price?: number | { readonly [field: string]: unknown };
		readonly Id?: string;
		readonly IdAt?: number;
		readonly Legs?: ReadonlyArray<TakeLeg>;
	}

	interface ConfirmOptions {
		readonly Price?: number | { readonly [field: string]: unknown };
		readonly Legs?: ReadonlyArray<TakeLeg>;
	}

	interface GatherOptions {
		readonly Kind?: string;
		readonly Id?: string;
		readonly IdAt?: number;
	}

	interface DepositOptions {
		readonly From?: KeyOfStore;
		readonly Field?: string;
		readonly Kind?: string;
		readonly Part?: number;
	}

	interface WithdrawOptions {
		readonly Kind?: string;
	}

	interface Quantity {
		Total(maxAge?: number): LuaTuple<[QuantityTotal | undefined, Reason | undefined]>;
		Take(count: number, options?: TakeOptions): LuaTuple<[boolean, Took | Reason, Info | undefined]>;
		Gather(count: number, to: KeyOfStore, field: string, options?: GatherOptions): LuaTuple<[boolean, Reason | undefined, Info | undefined]>;
		Hold(count: number, duration: number): LuaTuple<[boolean, HoldHandle | Reason, Info | undefined]>;
		Open(): LuaTuple<[boolean, Reason | undefined, Info | undefined]>;
		Close(): LuaTuple<[boolean, Closed | Reason, Info | undefined]>;
		Confirm(hold: HoldHandle, options?: ConfirmOptions): LuaTuple<[boolean, number | Reason | undefined, Info | undefined]>;
		Release(hold: HoldHandle): LuaTuple<[boolean, Reason | undefined, Info | undefined]>;
		Deposit(count: number, options?: DepositOptions): LuaTuple<[boolean, Reason | undefined, Info | undefined]>;
		Withdraw(
			count: unknown,
			part: number,
			to: number | KeyOfStore,
			field: string,
			options?: WithdrawOptions,
		): LuaTuple<[boolean, Reason | undefined, Info | undefined]>;
	}

	interface KeyPages<K = string | number> {
		Next(): LuaTuple<[ReadonlyArray<K> | undefined, Reason | undefined]>;
	}

	interface SessionCommon<D, O = never> {
		Get(): Frozen<D>;
		Observe(): Observer<Frozen<D>>;
		ObserveFates(): Observer<Fate<O>>;
		DidApply(name: Applied | Name, options?: DidApplyOptions): LuaTuple<[boolean | undefined, Reason | undefined, DidApplyInfo | undefined]>;
		Flush(): LuaTuple<[boolean, Reason | undefined, Info | undefined]>;
		Refresh(): LuaTuple<[boolean, Reason | undefined]>;
		Release(): LuaTuple<[boolean, Reason | undefined, Info | undefined]>;
	}

	interface TypedSession<D, O> extends SessionCommon<D, O> {
		Apply(op: Op<O>): LuaTuple<[boolean, Applied | Reason, Info | undefined]>;
		Commit(op: Op<O>, options?: CommitOptions): LuaTuple<[boolean, Frozen<D> | Reason, Info<D> | undefined]>;
	}

	interface Session<D> extends SessionCommon<D> {
		Apply(op: Op): LuaTuple<[boolean, Applied | Reason, Info | undefined]>;
		Commit(op: Op, options?: CommitOptions): LuaTuple<[boolean, Frozen<D> | Reason, Info<D> | undefined]>;
	}

	interface StoreCommon<D> {
		Peek(key: KeyLike, freshness?: number | PeekOptions): LuaTuple<[Frozen<D> | undefined, Reason | undefined, Info<D> | undefined]>;
		Inspect(key: KeyLike): LuaTuple<[Record<D> | undefined, Reason | undefined]>;
		DidApply(key: KeyLike, name: Name, options?: DidApplyOptions): LuaTuple<[boolean | undefined, Reason | undefined]>;
		Reset(key: KeyLike, options?: ResetOptions<D>): LuaTuple<[boolean, Cut | Reason, Info | undefined]>;
		Erase(key: KeyLike, options?: EraseOptions): LuaTuple<[boolean, Cut | Reason, Info | undefined]>;
		Losses(key: KeyLike): LuaTuple<[LossRecords | undefined, Reason | undefined]>;
		Pending(key: KeyLike): LuaTuple<[PendingItems | undefined, Reason | undefined]>;
		Resettle(key: KeyLike): LuaTuple<[boolean, Reason | undefined, Info | undefined]>;
		Follow(key: KeyLike): Observer<Frozen<D> | "Behind">;
		Stale(): Observer<string | number>;
		Bump(total: string, amount: number, options?: BumpOptions): LuaTuple<[boolean, Reason | undefined, Info | undefined]>;
		Total(name: string, maxAge?: number): LuaTuple<[number | undefined, Reason | undefined]>;
		Quantity(name: string): Quantity;
		Keys(): KeyPages;
		Unload(player: Player): void;
		IsLoaded(player: Player): boolean;
		Read(player: Player): Frozen<D> | undefined;
		Destroy(): void;
	}

	interface TypedStore<D, O> extends StoreCommon<D> {
		Edit(key: KeyLike, op: Op<O>, options?: EditOptions): LuaTuple<[boolean, Reason | undefined, Info<D> | undefined]>;
		Load(player: Player): LuaTuple<[TypedSession<D, O> | undefined, Reason | undefined]>;
		Get(player: Player): TypedSession<D, O> | undefined;
		Expect(player: Player): TypedSession<D, O>;
		WaitForLoaded(player: Player): TypedSession<D, O> | undefined;
		Leg(key: KeyLike, op: Op<O>, options?: LegOptions): Leg;
	}

	interface Store<D> extends StoreCommon<D> {
		Edit(key: KeyLike, op: Op, options?: EditOptions): LuaTuple<[boolean, Reason | undefined, Info<D> | undefined]>;
		Load(player: Player): LuaTuple<[Session<D> | undefined, Reason | undefined]>;
		Get(player: Player): Session<D> | undefined;
		Expect(player: Player): Session<D>;
		WaitForLoaded(player: Player): Session<D> | undefined;
		Leg(key: KeyLike, op: Op, options?: LegOptions): Leg;
	}

	interface Entries {
		readonly Reason: { readonly [R in Reason]: R };
		readonly New: {
			<D, O>(this: void, config: TypedConfig<D, O>): TypedStore<D, O>;
			<D>(this: void, config: Config<D>): Store<D>;
		};
		readonly Now: (this: void) => number;
		readonly Id: (this: void) => LuaTuple<[OpId | undefined, Reason | undefined]>;
		readonly Tx: (this: void, legs: ReadonlyArray<TxLeg>, options?: TxOptions) => LuaTuple<[boolean, Reason | undefined, Info | undefined]>;
		readonly CloseAll: (this: void) => void;
		readonly BeforeClose: (this: void, fn: (this: void) => void) => void;
	}
}

declare const Ledger: Ledger.Entries;

export = Ledger;
