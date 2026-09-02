declare namespace Ledger {
	type Reason = "Refused" | "Busy" | "Spent" | "Unresolved" | "Closed" | "Backlog" | "Full" | "Invalid" | "Behind" | "Held";

	type KeyLike = number | string;

	type KeysMode = "Player" | "String";

	type Fields<F> = F & {
		readonly Once?: string;
		readonly Id?: never;
		readonly Kind?: never;
		readonly OnceAt?: never;
	};

	interface OpenOp {
		readonly Id: string;
		readonly Kind: string;
		readonly Once?: string;
		readonly [field: string]: unknown;
	}

	type OpOf<O, K extends keyof O & string> = {
		readonly Id: string;
		readonly Kind: K;
		readonly Once?: string;
	} & Readonly<O[K]>;

	type Op<O extends OpMap<O> = never> = [O] extends [never] ? OpenOp : { [K in keyof O & string]: OpOf<O, K> }[keyof O & string];

	type Reducer<S, O extends OpMap<O> = never> = (this: void, state: S, op: Op<O>) => S | undefined;

	type NumberKeys<D> = { [K in keyof D]-?: D[K] extends number ? K : never }[keyof D] & string;

	type Migration = MigrationStep | { readonly Apply: MigrationStep; readonly Compatible?: boolean };

	type MigrationStep = { Step(this: void, state: unknown): object }["Step"];

	type OpMap<O = object> = { readonly [K in keyof O]: object };

	interface Mocked {
		readonly Players?: number;
		readonly CCU?: number;
		readonly Throttled?: boolean;
	}

	interface HistoryEntry {
		readonly Version: string;
		readonly At: number;
		readonly Deleted: boolean;
	}

	interface Record<S> {
		readonly Snapshot?: S;
		readonly Bytes?: number;
		readonly Ops: ReadonlyArray<OpenOp>;
		readonly Seen: ReadonlyArray<string>;
		readonly Version?: number;
		readonly Floor?: number;
		readonly Envelope?: number;
		readonly Erased?: number;
	}

	interface HoldOptions {
		readonly Hold?: number;
		readonly To?: KeyLike;
	}

	interface TxLeg {
		readonly Store?: StoreCommon<object>;
		readonly UserId?: number;
		readonly Key?: string;
		readonly Kind: string;
		readonly Fields?: object;
	}

	interface DataStoreLike {
		GetAsync(key: string): LuaTuple<[unknown, unknown]>;
		UpdateAsync(key: string, transform: (this: void, current: unknown, info: unknown) => unknown): LuaTuple<[unknown, unknown]>;
		RemoveAsync(key: string): LuaTuple<[unknown, unknown]>;
		GetVersionAsync(key: string, version: string): LuaTuple<[unknown, unknown]>;
		ListVersionsAsync(key: string, direction?: Enum.SortDirection, minDate?: number, maxDate?: number, pageSize?: number): DataStoreVersionPages;
		ListKeysAsync(prefix?: string, pageSize?: number, cursor?: string, excludeDeleted?: boolean): DataStoreKeyPages;
	}

	interface Hook {
		readonly Open: (this: void, name: string) => DataStoreLike;
		readonly Budget: (this: void, kind: Enum.DataStoreRequestType) => number;
	}

	interface Future<T extends unknown[]> {
		Wait(): LuaTuple<T>;
		Wait(timeout: number): LuaTuple<Partial<T>>;
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

	interface SessionCommon<S> {
		readonly LogSize: number;
		readonly LogBytes: number;
		Get(): S;
		Flush(): Future<[boolean, Reason | undefined]>;
		Compact(): Future<[boolean, Reason | undefined]>;
		Release(): Future<[boolean, Reason | undefined]>;
		Observe(): Observer<S>;
		DidApply(id: string): boolean;
	}

	interface Session<S> extends SessionCommon<S> {
		Apply<F extends object>(kind: string, fields?: Fields<F>): LuaTuple<[boolean, Reason | undefined]>;
		Commit<F extends object>(kind: string, fields?: Fields<F>): Future<[boolean, Reason | undefined]>;
		CommitOp(op: Op): Future<[boolean, Reason | undefined]>;
	}

	interface TypedSession<S, O extends OpMap<O>> extends SessionCommon<S> {
		Apply<K extends keyof O & string>(kind: K, fields: Fields<O[K]>): LuaTuple<[boolean, Reason | undefined]>;
		Commit<K extends keyof O & string>(kind: K, fields: Fields<O[K]>): Future<[boolean, Reason | undefined]>;
		CommitOp(op: Op<O>): Future<[boolean, Reason | undefined]>;
	}

	interface StoreCommon<D extends object> {
		Load(player: Player): void;
		Unload(player: Player): void;
		IsLoaded(player: Player): boolean;
		Read(player: Player): D | undefined;
		Peek(key: KeyLike): Future<[D | undefined, Reason | undefined]>;
		Inspect(key: KeyLike): Future<[Record<D> | undefined, Reason | undefined]>;
		DidApply(key: KeyLike, id: string): Future<[boolean | undefined, Reason | undefined]>;
		History(key: KeyLike, limit?: number): Future<[ReadonlyArray<HistoryEntry> | undefined, Reason | undefined]>;
		PeekVersion(key: KeyLike, version: string): Future<[D | undefined, Reason | undefined]>;
		Transfer(from: KeyLike, to: KeyLike, amount: number, id?: string): Future<[boolean, Reason | undefined]>;
		Bump(name: string, field: NumberKeys<D>, amount: number): Future<[boolean, Reason | undefined]>;
		Total(name: string, field: NumberKeys<D>, maxAge?: number): Future<[number | undefined, Reason | undefined]>;
		Reserve(key: KeyLike, field: NumberKeys<D>, amount: number, id: string, options?: HoldOptions): Future<[boolean, Reason | undefined]>;
		Confirm(key: KeyLike, id: string): Future<[boolean, Reason | undefined]>;
		Release(key: KeyLike, id: string): Future<[boolean, Reason | undefined]>;
		Grant(key: KeyLike, id: string): Future<[boolean, Reason | undefined]>;
		Resettle(key: KeyLike): Future<[boolean, Reason | undefined]>;
		RecoverTransfers(key: KeyLike): Future<[boolean, Reason | undefined]>;
		ClearDelivered(key: KeyLike): Future<[boolean, Reason | undefined]>;
		Reset(key: KeyLike): Future<[boolean, Reason | undefined]>;
		Erase(key: KeyLike): Future<[boolean, Reason | undefined]>;
		Stale(): Observer<string>;
		Destroy(): void;
	}

	interface Store<D extends object> extends StoreCommon<D> {
		Get(player: Player): Session<D> | undefined;
		Expect(player: Player): Session<D>;
		WaitForLoaded(player: Player): Session<D> | undefined;
		Edit<F extends object>(key: KeyLike, kind: string, fields?: Fields<F>): Future<[boolean, Reason | undefined]>;
		Tx(id: string, legs: ReadonlyArray<TxLeg>): Future<[boolean, Reason | undefined]>;
	}

	interface TypedStore<D extends object, O extends OpMap<O>> extends StoreCommon<D> {
		Get(player: Player): TypedSession<D, O> | undefined;
		Expect(player: Player): TypedSession<D, O>;
		WaitForLoaded(player: Player): TypedSession<D, O> | undefined;
		Edit<K extends keyof O & string>(key: KeyLike, kind: K, fields: Fields<O[K]>): Future<[boolean, Reason | undefined]>;
		Tx(id: string, legs: ReadonlyArray<TxLeg>): Future<[boolean, Reason | undefined]>;
	}

	interface ConfigCommon<D extends object> {
		readonly Name: string;
		readonly Default: D;
		readonly Balance?: NumberKeys<D>;
		readonly Migrations?: ReadonlyArray<Migration>;
		readonly Keys?: KeysMode;
		readonly OnLoadFailed?: (this: void, player: Player, why: Reason) => boolean;
		readonly Hook?: Hook;
		readonly Mock?: boolean | Mocked;
	}

	interface Config<D extends object> extends ConfigCommon<D> {
		readonly Reducer: Reducer<D>;
	}

	interface TypedConfig<D extends object, O extends OpMap<O>> extends ConfigCommon<D> {
		readonly Reducer: Reducer<D, O>;
	}

	interface Entries {
		readonly Reason: { readonly [R in Reason]: R };
		readonly New: <D extends object>(this: void, options: Config<D>) => Store<D>;
		readonly NewTyped: <D extends object, O extends OpMap<O>>(this: void, options: TypedConfig<D, O>) => TypedStore<D, O>;
		readonly Sweep: (this: void) => void;
		readonly CloseAll: (this: void) => void;
	}
}

declare const Ledger: Ledger.Entries;

export = Ledger;
