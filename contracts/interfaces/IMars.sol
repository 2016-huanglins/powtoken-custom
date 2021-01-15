pragma solidity >=0.5.0;

interface IMars {
    function balanceOf(address account) external view returns (uint);
    function transfer(address dst, uint rawAmount) external returns (bool);
}