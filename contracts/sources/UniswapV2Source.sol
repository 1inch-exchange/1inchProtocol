
// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../interfaces/IUniswapV2.sol";
import "../interfaces/IWETH.sol";
import "../IOneRouterView.sol";
import "../ISource.sol";

import "../libraries/UniERC20.sol";


library UniswapV2Helper {
    using Math for uint256;
    using SafeMath for uint256;
    using UniERC20 for IERC20;

    IUniswapV2Factory constant public FACTORY = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    IWETH constant public WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function getReturns(
        IUniswapV2Exchange exchange,
        IERC20 fromToken,
        IERC20 destToken,
        uint256[] memory amounts
    ) internal view returns (
        uint256[] memory results,
        uint256 reserveIn,
        uint256 reverseOut,
        bool needSync,
        bool needSkim
    ) {
        return _getReturns(
            exchange,
            fromToken.isETH() ? UniswapV2Helper.WETH : fromToken,
            destToken.isETH() ? UniswapV2Helper.WETH : destToken,
            amounts
        );
    }

    function _getReturns(
        IUniswapV2Exchange exchange,
        IERC20 fromToken,
        IERC20 destToken,
        uint256[] memory amounts
    ) private view returns (
        uint256[] memory results,
        uint256 reserveIn,
        uint256 reserveOut,
        bool needSync,
        bool needSkim
    ) {
        reserveIn = fromToken.uniBalanceOf(address(exchange));
        reserveOut = destToken.uniBalanceOf(address(exchange));
        (uint112 reserve0, uint112 reserve1,) = exchange.getReserves();
        if (fromToken > destToken) {
            (reserve0, reserve1) = (reserve1, reserve0);
        }
        needSync = (reserveIn < reserve0 || reserveOut < reserve1);
        needSkim = !needSync && (reserveIn > reserve0 || reserveOut > reserve1);

        reserveIn = Math.min(reserveIn, reserve0);
        reserveOut = Math.min(reserveOut, reserve1);

        results = new uint256[](amounts.length);
        for (uint i = 0; i < amounts.length; i++) {
            results[i] = calculateUniswapV2Formula(reserveIn, reserveOut, amounts[i]);
        }
    }

    function calculateUniswapV2Formula(uint256 reserveIn, uint256 reserveOut, uint256 amount) internal pure returns(uint256) {
        if (amount > 0) {
            return amount.mul(reserveOut).mul(997).div(
                reserveIn.mul(1000).add(amount.mul(997))
            );
        }
    }
}


contract UniswapV2SourceView {
    using SafeMath for uint256;
    using UniERC20 for IERC20;
    using UniswapV2Helper for IUniswapV2Exchange;

    function _calculateUniswapV2(IERC20 fromToken, uint256[] memory amounts, IOneRouterView.Swap memory swap) internal view returns(uint256[] memory rets, address dex, uint256 gas) {
        rets = new uint256[](amounts.length);

        IERC20 fromTokenWrapped = fromToken.isETH() ? UniswapV2Helper.WETH : fromToken;
        IERC20 destTokenWrapped = swap.destToken.isETH() ? UniswapV2Helper.WETH : swap.destToken;
        IUniswapV2Exchange exchange = UniswapV2Helper.FACTORY.getPair(fromTokenWrapped, destTokenWrapped);
        if (exchange == IUniswapV2Exchange(0)) {
            return (rets, address(0), 0);
        }

        for (uint t = 0; t < swap.disabledDexes.length && swap.disabledDexes[t] != address(0); t++) {
            if (swap.disabledDexes[t] == address(exchange)) {
                return (rets, address(0), 0);
            }
        }

        (rets,,,,) = exchange.getReturns(fromToken, swap.destToken, amounts);
        return (rets, address(exchange), 50_000 + (fromToken.isETH() || swap.destToken.isETH() ? 0 : 30_000));
    }
}


contract UniswapV2SourceSwap {
    using UniERC20 for IERC20;
    using SafeMath for uint256;
    using UniswapV2Helper for IUniswapV2Exchange;

    function _swapOnUniswapV2(IERC20 fromToken, IERC20 destToken, uint256 amount, uint256 flags) internal {
        if (fromToken.isETH()) {
            UniswapV2Helper.WETH.deposit{ value: amount }();
        }

        _swapOnUniswapV2Wrapped(
            fromToken.isETH() ? UniswapV2Helper.WETH : fromToken,
            destToken.isETH() ? UniswapV2Helper.WETH : destToken,
            amount,
            flags
        );

        if (destToken.isETH()) {
            UniswapV2Helper.WETH.withdraw(UniswapV2Helper.WETH.balanceOf(address(this)));
        }
    }

    function _swapOnUniswapV2Wrapped(IERC20 fromToken, IERC20 destToken, uint256 amount, uint256 /*flags*/) private {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        IUniswapV2Exchange exchange = UniswapV2Helper.FACTORY.getPair(fromToken, destToken);
        (
            /*uint256[] memory returnAmounts*/,
            uint256 reserveIn,
            uint256 reserveOut,
            bool needSync,
            bool needSkim
        ) = exchange.getReturns(fromToken, destToken, amounts);

        if (needSync) {
            exchange.sync();
        }
        else if (needSkim) {
            exchange.skim(0x68a17B587CAF4f9329f0e372e3A78D23A46De6b5);
        }

        fromToken.uniTransfer(payable(address(exchange)), amount);
        uint256 confirmed = fromToken.uniBalanceOf(address(exchange)).sub(reserveIn);
        uint256 returnAmount = UniswapV2Helper.calculateUniswapV2Formula(reserveIn, reserveOut, confirmed);

        if (fromToken < destToken) {
            exchange.swap(0, returnAmount, address(this), "");
        } else {
            exchange.swap(returnAmount, 0, address(this), "");
        }
    }
}


contract UniswapV2SourcePublic is ISource, UniswapV2SourceView, UniswapV2SourceSwap {
    function calculate(IERC20 fromToken, uint256[] memory amounts, IOneRouterView.Swap memory swap) public view override returns(uint256[] memory rets, address dex, uint256 gas) {
        return _calculateUniswapV2(fromToken, amounts, swap);
    }

    function swap(IERC20 fromToken, IERC20 destToken, uint256 amount, uint256 flags) public override {
        return _swapOnUniswapV2(fromToken, destToken, amount, flags);
    }
}
