# Style Guide

How we write Solidity and organize repos across the Juicebox V6 ecosystem. `nana-core-v6` is the gold standard — when in doubt, match what it does.

**This repo's deviations:** `via_ir = true` (stack depth).

## File Organization

```
src/
├── Contract.sol              # Main contracts in root
├── abstract/                 # Base contracts (JBPermissioned, JBControlled)
├── enums/                    # One enum per file
├── interfaces/               # One interface per file, prefixed with I
├── libraries/                # Pure/view logic, prefixed with JB
├── periphery/                # Utility contracts (deadlines, price feeds)
└── structs/                  # One struct per file, prefixed with JB
```

One contract/interface/struct/enum per file. Name the file after the type it contains.

**Structs, enums, libraries, and interfaces always go in their subdirectories** (`src/structs/`, `src/enums/`, `src/libraries/`, `src/interfaces/`) — never inline in contract files or placed in `src/` root. This keeps type definitions discoverable and import paths consistent across repos.

## Pragma Versions

```solidity
// Contracts — pin to exact version
pragma solidity 0.8.26;

// Interfaces, structs, enums — caret for forward compatibility
pragma solidity ^0.8.0;

// Libraries — caret, may use newer features
pragma solidity ^0.8.17;
```

## Imports

Named imports only. Grouped by source, alphabetized within each group:

```solidity
// External packages (alphabetized)
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

// Local: abstract contracts
import {JBPermissioned} from "./abstract/JBPermissioned.sol";

// Local: interfaces (alphabetized)
import {IJBController} from "./interfaces/IJBController.sol";
import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {IJBMultiTerminal} from "./interfaces/IJBMultiTerminal.sol";

// Local: libraries (alphabetized)
import {JBConstants} from "./libraries/JBConstants.sol";
import {JBFees} from "./libraries/JBFees.sol";

// Local: structs (alphabetized)
import {JBAccountingContext} from "./structs/JBAccountingContext.sol";
import {JBSplit} from "./structs/JBSplit.sol";
```

## Contract Structure

Section banners divide the contract into a fixed ordering. Every contract with 50+ lines uses these banners:

```solidity
/// @notice One-line description.
contract JBExample is JBPermissioned, IJBExample {
    // A library that does X.
    using SomeLib for SomeType;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBExample_SomethingFailed(uint256 amount);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    uint256 public constant override FEE = 25;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    uint256 internal constant _FEE_BENEFICIARY_PROJECT_ID = 1;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    IJBDirectory public immutable override DIRECTORY;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ---------------------- receive / fallback ------------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // --------------------------- modifiers ----------------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ----------------------- private helpers --------------------------- //
    //*********************************************************************//
}
```

**Section order:**
1. `using` declarations
2. Custom errors
3. Public constants
4. Internal constants
5. Public immutable stored properties
6. Internal immutable stored properties
7. Public stored properties
8. Internal stored properties
9. Constructor
10. `receive` / `fallback`
11. Modifiers
12. External transactions
13. External views
14. Public transactions
15. Internal helpers
16. Internal views
17. Private helpers

Functions are alphabetized within each section.

**Events:** Events are declared in interfaces only, never in implementation contracts. Implementations inherit events from their interface and emit them unqualified. This keeps the ABI definition in one place and allows tests to use interface-qualified event expectations (e.g., `emit IJBController.LaunchProject(...)`).

## Interface Structure

```solidity
/// @notice One-line description.
interface IJBExample is IJBBase {
    // Events (with full NatSpec)

    /// @notice Emitted when X happens.
    /// @param projectId The ID of the project.
    /// @param amount The amount transferred.
    event SomethingHappened(uint256 indexed projectId, uint256 amount);

    // Views (alphabetized)

    /// @notice The directory of terminals and controllers.
    function DIRECTORY() external view returns (IJBDirectory);

    // State-changing functions (alphabetized)

    /// @notice Does the thing.
    /// @param projectId The ID of the project.
    /// @return result The result.
    function doThing(uint256 projectId) external returns (uint256 result);
}
```

**Rules:**
- Events first, then views, then state-changing functions
- No custom errors in interfaces — errors belong in the implementing contract
- Full NatSpec on every event, function, and parameter
- Alphabetized within each group

## Naming

| Thing | Convention | Example |
|-------|-----------|---------|
| Contract | PascalCase | `JBMultiTerminal` |
| Interface | `I` + PascalCase | `IJBMultiTerminal` |
| Library | PascalCase | `JBCashOuts` |
| Struct | PascalCase | `JBRulesetConfig` |
| Enum | PascalCase | `JBApprovalStatus` |
| Enum value | PascalCase | `ApprovalExpected` |
| Error | `ContractName_ErrorName` | `JBMultiTerminal_FeeTerminalNotFound` |
| Public constant | `ALL_CAPS` | `FEE`, `MAX_FEE` |
| Internal constant | `_ALL_CAPS` | `_FEE_HOLDING_SECONDS` |
| Public immutable | `ALL_CAPS` | `DIRECTORY`, `PERMISSIONS` |
| Public/external function | `camelCase` | `cashOutTokensOf` |
| Internal/private function | `_camelCase` | `_processFee` |
| Internal storage | `_camelCase` | `_accountingContextForTokenOf` |
| Function parameter | `camelCase` | `projectId`, `cashOutCount` |

## NatSpec

**Contracts:**
```solidity
/// @notice One-line description of what the contract does.
contract JBExample is IJBExample {
```

**Functions:**
```solidity
/// @notice Records funds being added to a project's balance.
/// @param projectId The ID of the project which funds are being added to.
/// @param token The token being added.
/// @param amount The amount added, as a fixed point number with the same decimals as the terminal.
/// @return surplus The new surplus after adding.
function recordAddedBalanceFor(
    uint256 projectId,
    address token,
    uint256 amount
) external override returns (uint256 surplus) {
```

**Structs:**
```solidity
/// @custom:member duration The number of seconds the ruleset lasts for. 0 means it never expires.
/// @custom:member weight How many tokens to mint per unit paid (18 decimals).
/// @custom:member weightCutPercent How much weight decays each cycle (9 decimals).
struct JBRulesetConfig {
    uint32 duration;
    uint112 weight;
    uint32 weightCutPercent;
}
```

**Mappings:**
```solidity
/// @notice Context describing how a token is accounted for by a project.
/// @custom:param projectId The ID of the project.
/// @custom:param token The address of the token.
mapping(uint256 projectId => mapping(address token => JBAccountingContext)) internal _accountingContextForTokenOf;
```

## Numbers

Use underscores for thousands separators:

```solidity
uint256 internal constant _FEE_HOLDING_SECONDS = 2_419_200; // 28 days
uint32 public constant MAX_WEIGHT_CUT_PERCENT = 1_000_000_000;
uint256 public constant MAX_RESERVED_PERCENT = 10_000;
```

## Function Calls

Use named parameters for readability when calling functions with 3+ arguments:

```solidity
PERMISSIONS.hasPermission({
    operator: sender,
    account: account,
    projectId: projectId,
    permissionId: permissionId,
    includeRoot: true,
    includeWildcardProjectId: true
});
```

## Multiline Signatures

```solidity
function recordCashOutFor(
    address holder,
    uint256 projectId,
    uint256 cashOutCount,
    JBAccountingContext calldata accountingContext
)
    external
    override
    returns (
        JBRuleset memory ruleset,
        uint256 reclaimAmount,
        JBCashOutHookSpecification[] memory hookSpecifications
    )
{
```

Modifiers and return types go on their own indented lines.

## Error Handling

- Validate inputs with explicit `revert` + custom error
- Use `try-catch` only for external calls to untrusted contracts (hooks, fee processing)
- Always include relevant context in error parameters

```solidity
// Direct validation
if (amount > limit) revert JBTerminalStore_InadequateControllerPayoutLimit(amount, limit);

// External call to untrusted hook
try hook.afterPayRecordedWith(context) {} catch (bytes memory reason) {
    emit HookAfterPayReverted(hook, context, reason, _msgSender());
}
```

---

## DevOps

### foundry.toml

Standard config across all repos:

```toml
[profile.default]
solc = '0.8.26'
evm_version = 'paris'
optimizer_runs = 200
libs = ["node_modules", "lib"]
fs_permissions = [{ access = "read-write", path = "./"}]
via_ir = true

[profile.ci_sizes]
optimizer_runs = 200

[fuzz]
runs = 4096

[invariant]
runs = 1024
depth = 100
fail_on_revert = false

[fmt]
number_underscore = "thousands"
multiline_func_header = "all"
wrap_comments = true
```

**Variations:**
- `evm_version = 'cancun'` for repos using transient storage (buyback-hook, router-terminal, univ4-router)
- `via_ir = true` for repos hitting stack-too-deep (buyback-hook, banny-retail, univ4-lp-split-hook, deploy-all)
- `optimizer = false` only for deploy-all-v6 (stack-too-deep with optimization)

### CI Workflows

Every repo has at minimum `test.yml` and `lint.yml`:

**test.yml:**
```yaml
name: test
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
jobs:
  forge-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - uses: actions/setup-node@v4
        with:
          node-version: 22.4.x
      - name: Install npm dependencies
        run: npm install --omit=dev
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
      - name: Run tests
        run: forge test --fail-fast --summary --detailed --skip "*/script/**"
      - name: Check contract sizes
        run: FOUNDRY_PROFILE=ci_sizes forge build --sizes --skip "*/test/**" --skip "*/script/**" --skip SphinxUtils
```

**lint.yml:**
```yaml
name: lint
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
jobs:
  forge-fmt:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
      - name: Check formatting
        run: forge fmt --check
```

### package.json

```json
{
  "name": "@bananapus/univ4-lp-split-hook-v6",
  "version": "x.x.x",
  "license": "MIT",
  "repository": { "type": "git", "url": "git+https://github.com/Org/repo.git" },
  "engines": { "node": ">=20.0.0" },
  "scripts": {
    "test": "forge test",
    "coverage": "forge coverage --match-path \"./src/*.sol\" --report lcov --report summary"
  },
  "dependencies": { ... },
  "devDependencies": {
    "@sphinx-labs/plugins": "^0.33.2"
  }
}
```

**Scoping:** `@bananapus/` for Bananapus repos, `@rev-net/` for revnet, `@croptop/` for croptop, `@bannynet/` for banny, `@ballkidz/` for defifa.

### remappings.txt

Every repo has a `remappings.txt`. Minimal content:

```
@sphinx-labs/contracts/=lib/sphinx/packages/contracts/contracts/foundry
```

Additional mappings as needed for repo-specific dependencies.

### Formatting

Run `forge fmt` before committing. The `[fmt]` config in `foundry.toml` enforces:
- Thousands separators on numbers (`1_000_000`)
- Multiline function headers when multiple parameters
- Wrapped comments at reasonable width

CI checks formatting via `forge fmt --check`.

### Branching

- `main` is the primary branch
- Feature branches for PRs
- All PRs trigger test + lint workflows
- Submodule checkout with `--recursive` in CI

### Dependencies

- Solidity dependencies via npm (`node_modules/`)
- `forge-std` as a git submodule in `lib/`
- Sphinx plugins as a devDependency
- Cross-repo references use `file:../sibling-repo` in local development
- Published versions use semver ranges (`^0.0.x`) for npm

### Contract Size Checks

CI runs `FOUNDRY_PROFILE=ci_sizes forge build --sizes` to catch contracts approaching the 24KB limit. The `ci_sizes` profile uses `optimizer_runs = 200` for realistic size measurement even when the default profile has different optimizer settings.
