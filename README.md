# Battleshop Helper (client addon)

Battle-shop replacement for the 7.3.5 client: a full replica of the shop layout
(category rail, product-card grid, Buy Now, page arrows) with a live try-on pane
showing the player's **real character model**. Click a card to try it on (picks
stack, exactly like the Dressing Room), hover for real stat tooltips and card
descriptions, and buy through a server-validated confirmation. No client
patching — this is an ordinary unsigned addon.

When the server sets `Battlepay.FittingRoom.ReplaceShop = 1`, the addon
intercepts the shop button (micro menu, Esc menu, and `ToggleStoreUI`) and opens
this window instead of the Blizzard store. Players without the addon — or with
the bridge disabled — always get the real store; the fallback is automatic
because the hook is only installed after a successful server handshake. A
"Standard Shop" footer button keeps the original store reachable.

The in-world preview (the mirror clone behind **In World**, and the `.preview`
command) works alongside the panel.

Battle pets render in the pane like mounts (their creature display), and the
"In World" button summons the actual pet next to you, visible only to you.

## Featured (splash) categories

The replica follows the store's own mechanic: a **category** renders as a
featured page when its `battlepay_product_group.DisplayType` is `1` (`Splash`)
- one hero card above two smaller ones - instead of the 4x2 grid. Ordering
within the group decides which product gets the hero slot. The cards are
styled after the store's: gold-framed warm gradient panels, a parchment
FEATURED! ribbon over the hero, Morpheus serif type, a pulsing starburst
behind the icon, the original price struck through, and a green discount
badge.

```sql
UPDATE battlepay_product_group SET DisplayType = 1 WHERE GroupID = <id>;
```

Sale pricing is separate and also matches the store: whenever a product's
`NormalPriceFixedPoint` exceeds its `CurrentPriceFixedPoint`, the original
price is shown greyed against the green sale price, with a discount badge on
featured cards.

```sql
UPDATE battlepay_product SET NormalPriceFixedPoint = 200, CurrentPriceFixedPoint = 150
WHERE ProductID = <id>;   -- shows as 200 -> 150 with a -25% badge
```

## DoubleWide categories

`DisplayType = 2` (`DoubleWide`) renders the category as four large plates,
two by two, instead of the 4x2 grid - the same gold-framed warm gradient as
the featured cards, with a big ringed icon and the name centred above the
prices. When the product is discounted, a green **You save N%** banner sits
in the plate's top corner; `N` is computed from that product's own
`NormalPriceFixedPoint` and `CurrentPriceFixedPoint`, so it always reflects
the real saving.

```sql
UPDATE battlepay_product_group SET DisplayType = 2 WHERE GroupID = <id>;
```

## Custom items

The catalog is resilient to items the client cache cannot resolve: the server
always ships the card name, icon FileDataID and quality, so custom items render
correctly in the grid regardless. For the rest to work, a custom item needs its
hotfix rows served to the client:

- **Stat tooltips**: `Item` + `ItemSparse` hotfix rows (the usual custom-item set).
- **Try-on / clone preview**: additionally `ItemAppearance` (with a valid
  `ItemDisplayInfoID`) and `ItemModifiedAppearance` (appearance mod 0) rows, or
  the model has nothing to render. Without them the card still works - only the
  dressing behavior is skipped.

## Install

Copy this folder into the client so you have:

```
World of Warcraft\Interface\AddOns\BattleshopHelper\BattleshopHelper.toc
World of Warcraft\Interface\AddOns\BattleshopHelper\BattleshopHelper.lua
```

Enable it on the character screen's AddOns list if it isn't already.

## Use

- `/battleshop`, `/bsh` or `/shop` toggles the panel (or just click the shop
  button). `/fitroom` and `/fittingroom` still work.
- Opening the in-game shop also offers a **Battleshop Helper** button.
- Click products to try them on; drag the model to rotate; **Undress** / **Reset**
  manage the model; **Buy** purchases the selected product after a confirmation.
- **Mouse wheel** turns the page; over the model pane it zooms instead.
- When you click Buy inside the *real* shop, the previewed items are tried on in
  the panel automatically.

## Server requirements

- The server must run with the matching addon bridge
  (`src/server/scripts/BattlePay/battlepay_fitting_room.cpp`).
- `Battlepay.FittingRoom.Enable` and `Battlepay.FittingRoom.Addon` must be 1
  (both default on), and `AddonChannel` must be 1 (default). The config keys
  and the `PRVFIT` addon prefix keep their original names so an updated addon
  still talks to an older server.

## Protocol (for maintainers)

Addon prefix `PRVFIT`; client messages are self-whispers prefixed `FITROOM:`,
consumed server-side (never echoed). Server pushes: `VER`, `GRP`, `PRD`
(batched `id,group,price,kind,payload` entries), `END`, `BAL`, `CFM`
(purchase confirmation token), `RES` (result), `TRY`/`TRYM` (live try-on
relays), `OPN` (shop opened), `DSC` (product description). PRD entries are
`id,group,price,kind,data,icon,quality,name` with kinds I (wearables),
M (mount), P (battle pet), G (everything else). Client sends: `HELLO`, `CAT`,
`BUY|productId`, `CFM|token|0/1`, `PRV|productId` (preview on the in-world
clone or summon the pet), `DESC|productId` (lazy description fetch).
