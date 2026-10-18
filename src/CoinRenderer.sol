// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {ICore} from "./interfaces/ICore.sol";
import {ICoinRenderer} from "./interfaces/ICoinRenderer.sol";
import {IArtCoinsTokenV2} from "./interfaces/ArtCoinsV2.sol";
import {ICredits, Mainnet} from "./interfaces/Interfaces.sol";
import {CreditDrawing} from "./lib/CreditDrawing.sol";

/// @notice the coin's metadata renderer: the Core's pile drawn as a Statement page, 8 columns by 10 rows.
/// @dev    retained for an owner swap after the LogoCoinRenderer launch. the constructor owner keeps its CREATE2
/// address independent of the Core; `setCore` binds the Core once. a pile of at most 80 credits is drawn whole, in
/// pile order. a larger pile is read whole, then 80 of its credits are sampled by `block.prevrandao`, so the
/// selection changes each block and holds within a block. every cell is the credit's own drawing,
/// `CreditDrawing.body`, the code the live CreditArt and StatementArt run. a view contract: every call reads the
/// Core, Credits and the coin. the pile walk costs about 2,200 gas per pile credit and the page about 10,000,000
/// gas at 80 cells; the whole call is about 25,000,000 gas at 80 cells.
contract CoinRenderer is ICoinRenderer {
    uint256 private constant COLS = 8;
    uint256 private constant ROWS = 10;
    uint256 private constant PAGE = COLS * ROWS;
    ICredits private constant CREDITS = ICredits(Mainnet.CREDITS);

    address public immutable owner;
    ICore public core;

    constructor(address owner_) {
        owner = owner_;
    }

    /// @inheritdoc ICoinRenderer
    function setCore(ICore core_) external {
        if (msg.sender != owner) revert NotOwner();
        if (address(core) != address(0)) revert CoreSet();
        if (address(core_) == address(0)) revert ZeroCore();
        core = core_;
        emit CoreBound(address(core_));
    }

    /// the coin's metadata as a data URI: name, symbol and description read from `token`, the image `image()`
    function contractURI(address token) external view returns (string memory) {
        IArtCoinsTokenV2 t = IArtCoinsTokenV2(token);
        string memory json = string.concat(
            '{"name":',
            LibString.escapeJSON(t.name(), true),
            ',"symbol":',
            LibString.escapeJSON(t.symbol(), true),
            ',"description":',
            LibString.escapeJSON(t.description(), true),
            ',"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(image())),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// the pile as a page: every pile credit in pile order when the pile holds at most 80, else 80 pile credits
    /// sampled by `block.prevrandao`. reads the whole pile through `pilePage(0, pileSize())` before sampling, so a pile
    /// over 80 pays about 2,200 gas per pile credit to read the pile, then draws 80 cells
    function image() public view returns (string memory) {
        if (address(core) == address(0)) revert ZeroCore();
        uint256[] memory ids = core.pilePage(0, core.pileSize());
        bool sampled = ids.length > PAGE;
        uint256 n = sampled ? PAGE : ids.length;
        uint256 rnd = uint256(keccak256(abi.encode(block.prevrandao, ids.length)));
        bytes21[80] memory seeds;
        uint64[80] memory paidAt;
        for (uint256 i; i < n; ++i) {
            if (sampled) {
                uint256 j = i + rnd % (ids.length - i);
                (ids[i], ids[j]) = (ids[j], ids[i]);
                rnd = uint256(keccak256(abi.encode(rnd)));
            }
            seeds[i] = CREDITS.seedOf(ids[i]);
            paidAt[i] = CREDITS.timestampOf(ids[i]);
        }
        return page(seeds, paidAt, n);
    }

    /// the first `n` credits of `seeds` and `paidAt` on the page, cell by cell in reading order, the frame and cell
    /// placement of the live StatementArt. `n` at most 80. a credit draws with the plates its `paidAt` selects
    function page(bytes21[80] memory seeds, uint64[80] memory paidAt, uint256 n) public pure returns (string memory) {
        CreditDrawing.Buffer memory out = CreditDrawing.Buffer(new bytes(400_000), 0, new bytes(16 * 2768));
        CreditDrawing.put(
            out,
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10000 12500" shape-rendering="crispEdges"><rect width="10000" height="12500" fill="#ffffff"/>'
        );
        uint24[16] memory colors = CreditDrawing.palette();
        for (uint256 i; i < n; ++i) {
            CreditDrawing.put(
                out,
                string.concat(
                    '<svg x="',
                    LibString.toString(800 + (i % COLS) * 1050),
                    '" y="',
                    LibString.toString(820 + (i / COLS) * 1090),
                    '" width="1050" height="1050" viewBox="0 0 320 320">'
                )
            );
            CreditDrawing.body(out, seeds[i], CreditDrawing.platesAt(paidAt[i]), colors, true);
            CreditDrawing.put(out, "</svg>");
        }
        CreditDrawing.put(out, "</svg>");
        return CreditDrawing.finish(out);
    }
}
