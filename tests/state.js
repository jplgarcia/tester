/**
 * Shared mutable state across all test files.
 * Works because Jest runs with --runInBand (single process) and resetModules: false,
 * so this module is loaded once and the same object is returned on every require().
 */
const state = {
  // Input indices recorded during deposit tests — used by withdrawal tests
  idxEthDeposit: null,
  idxErc20Deposit: null,
  idxErc721Deposit: null,
  idxErc1155SingleDeposit: null,
  idxErc1155BatchDeposit: null,
};

export default state;
