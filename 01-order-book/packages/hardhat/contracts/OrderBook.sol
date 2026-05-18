// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract OrderBook {
    using SafeERC20 for IERC20;

    IERC20 public tokenA; // base token 
    IERC20 public tokenB; // quote token 

    enum OrderType { Buy, Sell } // order can only be of buy or sell type -(Buy = 0, Sell = 1)
    enum OrderStatus { Open, Closed } // order status can be open/closed (Open = 0, Closed = 1

    // Order structure to represent each order in the order book
    struct Order {
        address trader;
        OrderType orderType;
        uint256 amount;
        uint256 price;
        uint256 filled;
        OrderStatus status;
    }
    // array to store orders in order book - initially empty
    Order[] public orders;

    // Events for order placement, matching, and cancellation
    event OrderPlaced(uint256 orderId, address trader, uint8 orderType, address sellToken, address buyToken, uint256 amount, uint256 price); // Emit event with details of the placed order, including token addresses for clarity
    event OrderMatched(uint256 buyOrderId, uint256 sellOrderId, uint256 amount); // Emit event with details of the matched orders and fill amount
    event OrderCanceled(uint256 orderId); // Emit event with details of the canceled order

    // Custom errors for better error handling and gas efficiency
    error InvalidAmount(); // error when order amount is zero
    error InvalidPrice(); //error when order amount or price is zero
    error PriceMismatch(); // error when bid price is less than asking price
    error UnauthorizedCancellation(); // error when someone tries to cancel order they didn't place

    // Constructor to initialize the order book with the two tokens being traded
    constructor(address _tokenA, address _tokenB) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }
    // Function to place a buy order - buyer must escrow quote tokens upfront (amount = num tokens)
    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount(); // amount (number of tokens) must be > 0
        if (price == 0) revert InvalidPrice();  // price must be > 0

        orderId = orders.length; // order ID is the current length of the orders array
        // Create new buy order and add to order book - initialise filled to 0 and status as Open
        orders.push(Order({
            trader: msg.sender,
            orderType: OrderType.Buy,
            amount: amount,
            price: price,
            filled: 0, //
            status: OrderStatus.Open // order is open until fully filled or cancelled
        }));

        // Escrow tokenB (quote token) from buyer upfront
        tokenB.safeTransferFrom(msg.sender, address(this), amount * price);
        // Emit event with details of the placed order, including token addresses for clarity
        emit OrderPlaced(orderId, msg.sender, 0, address(tokenB), address(tokenA), amount, price);
    }
    // Function to place a sell order - seller must escrow base tokens upfront
    function placeSellOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();

        // Create new sell order and add to order book
        orderId = orders.length;
        orders.push(Order({
            trader: msg.sender,
            orderType: OrderType.Sell,
            amount: amount,
            price: price,
            filled: 0,
            status: OrderStatus.Open
        }));

        // Escrow tokenA (base token) from seller upfront
        tokenA.safeTransferFrom(msg.sender, address(this), amount);
        // Emit event with details of the placed order, including token addresses for clarity
        emit OrderPlaced(orderId, msg.sender, 1, address(tokenA), address(tokenB), amount, price);
    }

    // Function to match a buy order with a sell order - checks price and updates order statuses
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        Order storage buyOrder = orders[buyOrderId]; // Load buy order from storage
        Order storage sellOrder = orders[sellOrderId]; // Load sell order from storage

        // if buy order (bid)price is less than sell order (asking) price, then orders cannot be matched 
        if (buyOrder.price < sellOrder.price) revert PriceMismatch();

        uint256 buyRemaining = buyOrder.amount - buyOrder.filled; // Calculate remaining amount for buy order
        uint256 sellRemaining = sellOrder.amount - sellOrder.filled; // Calculate remaining amount for sell order
        uint256 fillAmount = buyRemaining < sellRemaining ? buyRemaining : sellRemaining; // Determine fill amount based on smaller remaining amount

        buyOrder.filled += fillAmount; // Update filled amount for buy order
        sellOrder.filled += fillAmount; // Update filled amount for sell order

        if (buyOrder.filled == buyOrder.amount) buyOrder.status = OrderStatus.Closed; // when filled amount = total buyer amount, close the buy order
        if (sellOrder.filled == sellOrder.amount) sellOrder.status = OrderStatus.Closed; // when filled amount = total seller amount, close the sell order

        tokenA.safeTransfer(buyOrder.trader, fillAmount); // Transfer base tokens from order book to buyer
        tokenB.safeTransfer(sellOrder.trader, fillAmount * buyOrder.price); // Transfer quote tokens from order book to seller based on buy order price (not sell order price, to ensure price priority for buyer)

        emit OrderMatched(buyOrderId, sellOrderId, fillAmount); // Emit event with details of the matched orders and fill amount
    }

    // Function to cancel an open order - only the original trader can cancel their order
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId]; // Load order from storage
        // only trader who placed order can cancel, otherwise revert with error
        if (order.trader != msg.sender) revert UnauthorizedCancellation();

        uint256 remainingAmount = order.amount - order.filled; // Calculate remaining amount that has not been filled yet
        order.status = OrderStatus.Closed; // Mark order as closed to prevent further matching

        // Refund remaining tokens to trader based on order type
        // If it's a buy order, refund the remaining quote tokens (tokenB) to the buyer. If it's a sell order, refund the remaining base tokens (tokenA) to the seller.
        if (order.orderType == OrderType.Buy) {
            tokenB.safeTransfer(order.trader, remainingAmount * order.price);
        } else {
            tokenA.safeTransfer(order.trader, remainingAmount);
        }

        emit OrderCanceled(orderId); // Emit event with details of the canceled order
    }
    // function returns remaining amount for a given order ID - useful for front-end display of order status
    function remaining(uint256 orderId) external view returns (uint256) {
        return orders[orderId].amount - orders[orderId].filled; // remaining = total order amount-filled amount
    }
    // function checks if an order is still open - returns true if order status is Open, false otherwise
    function isOpen(uint256 orderId) external view returns (bool) {
        return orders[orderId].status == OrderStatus.Open;
    }
}
