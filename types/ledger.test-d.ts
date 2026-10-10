import Ledger from "../index";

interface PlayerData {
	Gold: number;
	Items: Array<string>;
}

interface PlayerOps {
	AddGold: { Amount: number };
	SpendGold: { Amount: number };
	BuyItem: { Item: string; Price: number };
}

const PlayerStore = Ledger.New<PlayerData, PlayerOps>({
	Name: "PlayerData",
	Keys: "Player",
	Default: { Gold: 0, Items: [] },
	MustExist: false,
	Erasable: true,
	Balances: { Gold: { Credit: ["AddGold", { Kind: "Refund", Max: 1000000 }], Debit: "SpendGold", Max: 1000000 } },
	Reducer: (data, op) => {
		if (op.Kind === "BuyItem") {
			if (data.Gold < op.Price) {
				return undefined;
			}
			return { Gold: data.Gold - op.Price, Items: [...data.Items, op.Item] };
		}
		return undefined;
	},
	KickMessage: "Please rejoin.",
	Migrations: [{ Fields: ["Items"], Run: (stored) => stored }],
	Mock: {},
});

export function Positives(player: Player): void {
	const [loaded, why] = PlayerStore.Load(player);
	const loadReason: Ledger.Reason | undefined = why;
	if (loaded === undefined) {
		print(loadReason);
		return;
	}

	const gold: number = loaded.Get().Gold;
	const [applied, appliedResult] = loaded.Apply({ Kind: "AddGold", Amount: 5 });
	if (applied && typeIs(appliedResult, "table")) {
		const handle: Ledger.Applied = appliedResult;
		print(handle.CallId, gold);
	}

	const [committed, committedResult, committedInfo] = loaded.Commit({ Kind: "BuyItem", Item: "Sword", Price: 50 });
	if (!committed && committedInfo?.Outcome) {
		const [landed, landedWhy] = committedInfo.Outcome.Wait();
		print(landed, landedWhy, committedResult);
	}

	const [edited, editWhy] = PlayerStore.Edit(player.UserId, { Kind: "SpendGold", Amount: 10 }, { IdAt: Ledger.Now() });
	print(edited, editWhy === Ledger.Reason.Unresolved);

	const [data, peekWhy] = PlayerStore.Peek(player.UserId, 30);
	print(data?.Gold, peekWhy);

	const connection = PlayerStore.Follow(player.UserId)
		.Filter((value) => value !== "Behind")
		.Subscribe((value) => print(value));
	connection.Disconnect();

	const [name, idWhy] = Ledger.Id();
	if (name !== undefined) {
		PlayerStore.Erase(player.UserId, { Id: name });
	}
	print(idWhy);

	const [traded] = Ledger.Tx([
		PlayerStore.Leg(1, { Kind: "SpendGold", Amount: 5 }),
		PlayerStore.Leg(2, { Kind: "AddGold", Amount: 5 }),
	]);
	print(traded);

	loaded.ObserveFates().Subscribe((fate) => {
		if (fate.Fate.Kind === "Turned") {
			print(fate.Fate.Why, fate.Op.Kind);
		}
	});

	const stock = PlayerStore.Quantity("Sword");
	const [took, tookResult] = stock.Take(1, { Legs: [PlayerStore.Leg(player.UserId, { Kind: "BuyItem", Item: "Sword", Price: 10 }, { Slot: ["Items"] })] });
	if (took && typeIs(tookResult, "table")) {
		print(tookResult.Value);
	}

	const [page] = PlayerStore.Keys().Next();
	print(page?.size());

	Ledger.BeforeClose(() => print("closing"));
}

const OpenStore = Ledger.New<{ Count: number }>({
	Name: "Open",
	Keys: "String",
	Default: { Count: 0 },
	MustExist: false,
	Erasable: false,
});

export function Negatives(player: Player): void {
	// @ts-expect-error a kind that is not in PlayerOps
	PlayerStore.Edit(1, { Kind: "Sell", Amount: 1 });

	// @ts-expect-error AddGold carries Amount
	PlayerStore.Edit(1, { Kind: "AddGold" });

	// @ts-expect-error Amount is a number
	PlayerStore.Edit(1, { Kind: "AddGold", Amount: "5" });

	const session = PlayerStore.Expect(player);
	// @ts-expect-error Apply takes no options
	session.Apply({ Kind: "AddGold", Amount: 1 }, { Id: "x" });

	// @ts-expect-error data is read only
	session.Get().Gold = 5;

	// @ts-expect-error Erase takes an OpId, never text
	PlayerStore.Erase(1, { Id: "erase-1" });

	// @ts-expect-error a misspelt reason
	const reason: Ledger.Reason = "Bsuy";
	print(reason);

	// @ts-expect-error Erasable is required
	Ledger.New<{ Gold: number }>({ Name: "X", Keys: "String", Default: { Gold: 0 }, MustExist: false });

	// @ts-expect-error Keys is Player or String
	Ledger.New<{ Gold: number }>({ Name: "Y", Keys: "Other", Default: { Gold: 0 }, MustExist: false, Erasable: false });

	OpenStore.Edit("k", { Kind: "Anything", By: 2 });
}
