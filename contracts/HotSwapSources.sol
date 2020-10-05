// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ISource.sol";
import "./PathsAdvisor.sol";


contract HotSwapSources is Ownable {
    uint256 public sourcesCount;
    mapping(uint256 => ISource) public sources;
    PathsAdvisor public pathsAdvisor;

    constructor(uint256 _sourcesCount) public {
        sourcesCount = _sourcesCount;
        pathsAdvisor = new PathsAdvisor();
    }

    function setSource(uint256 index, ISource source) external onlyOwner {
        require(index <= sourcesCount, "Router: index is too high");
        sources[index] = source;
        sourcesCount = Math.max(sourcesCount, index + 1);
    }

    function setPathsAdvisor(PathsAdvisor newPathsAdvisor) external onlyOwner {
        pathsAdvisor = newPathsAdvisor;
    }

    function _getPathsForTokens(IERC20 fromToken, IERC20 destToken) internal view returns(IERC20[][] memory paths) {
        return pathsAdvisor.getPathsForTokens(fromToken, destToken);
    }
}
