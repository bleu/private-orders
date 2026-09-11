// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0 <0.9.0;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {PrivateTradeTerms} from "../interfaces/IPrivateTrade.sol";

/// @title PrivateTradeAppData
/// @notice Builds the order appData document that declares a private trade bundle.
///
/// @dev An Atomic Bundle is declared inside the order's appData:
///
/// ```json
/// {"version":"private-trades/1","wrappers":[
///   {"target":"0x...","data":"0x...","isOmittable":false}
/// ]}
/// ```
///
/// The order's `appData` field is the keccak256 of that document. The document is what a solver and
/// the driver read to learn which bundle to run and with what data; `CowWrapperHelpers` then
/// validates and encodes the chain.
///
/// `isOmittable` is always `false`. A private trade that skips its bundle is not a private trade.
///
/// @dev The document deliberately does not contain the appData hash, and the appData hash is
/// deliberately not part of `PrivateTradeTerms`. Putting it there would be a cycle: the terms are
/// carried in the bundle data, which lives inside this document.
library PrivateTradeAppData {
  /// @notice appData schema version for private trade documents.
  string internal constant VERSION = "private-trades/1";

  /// @dev The bytes a wrapper expects in `wrappers[].data`.
  function wrapperData(bytes32 declaredOfferId, PrivateTradeTerms memory terms) internal pure returns (bytes memory) {
    return abi.encode(declaredOfferId, terms);
  }

  /// @notice The canonical appData document for a single-bundle private trade.
  function document(address wrapper, bytes memory bundleData) internal pure returns (bytes memory) {
    return abi.encodePacked(
      '{"version":"',
      VERSION,
      '","wrappers":[{"target":"',
      Strings.toHexString(wrapper),
      '","data":"',
      _hex(bundleData),
      '","isOmittable":false}]}'
    );
  }

  /// @notice The value an order must carry in its `appData` field.
  function documentHash(address wrapper, bytes memory bundleData) internal pure returns (bytes32) {
    return keccak256(document(wrapper, bundleData));
  }

  /// @dev OZ 4.x has no bytes-to-hex helper; this library must stay dependency-light and pure.
  /// @dev OZ 4.x has no bytes-to-hex helper; this library must stay dependency-light and pure.
  function _hex(bytes memory data) private pure returns (string memory) {
    bytes memory table = bytes("0123456789abcdef");
    bytes memory out = new bytes(2 + data.length * 2);
    out[0] = "0";
    out[1] = "x";
    for (uint256 i = 0; i < data.length; ++i) {
      out[2 + i * 2] = table[uint8(data[i]) >> 4];
      out[3 + i * 2] = table[uint8(data[i]) & 0x0f];
    }
    return string(out);
  }
}
