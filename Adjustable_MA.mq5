//+------------------------------------------------------------------+
//|                                        Adjustable Moving Average |
//|                             Copyright © 2009-2025, EarnForex.com |
//|                                       https://www.earnforex.com/ |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2009-2025, EarnForex"
#property link      "https://www.earnforex.com/metatrader-expert-advisors/Adjustable-MA/"
#property version   "1.07"

#property description "Adjustable MA EA - expert advisor for customizable MA trading."
#property description "Modify StopLoss, TakeProfit, TrailingStop, MA Period, MA Type"
#property description "and minimum difference between MAs to count as cross."

#include <Trade/Trade.mqh>

enum ENUM_TRADE_DIRECTION
{
    TRADE_DIRECTION_LONG, // Long-only
    TRADE_DIRECTION_SHORT, // Short-only
    TRADE_DIRECTION_BOTH // Both
};

input group "Main"
input int Period_1 = 20;
input int Period_2 = 22;
input ENUM_MA_METHOD MA_Method = MODE_EMA;
input int MinDiff = 3; // MinDiff: Minimum difference between MAs for a Cross to count.
input int StopLoss = 0;
input int TakeProfit = 0;
input int TrailingStop = 0;
input ENUM_TRADE_DIRECTION TradeDirection = TRADE_DIRECTION_BOTH;
input string StartTime = "00:00"; // Start time (Server), inclusive
input string EndTime =   "23:59"; // End time (Server), inclusive
input bool CloseTradesOutsideTradingTime = true;
input bool DoTrailingOutsideTradingTime = true;
input group "Money management"
input double Lots = 0.1;
input bool UseMM = false;
input double LotsPer10000 = 1; // LotsPer10000: Number of lots per every 10,000 of free margin.
input group "Miscellaneous"
input int Slippage = 3;
input string OrderCommentary = "Adjustable MA";

// Main trading object.
CTrade *Trade;

// Depend on broker's quotes:
double Poin;
ulong Deviation;

int LastBars = 0;

// 0 - undefined, 1 - bullish cross (fast MA above slow MA), -1 - bearish cross (fast MA below slow MA).
int PrevCross = 0;

int Magic; // Will work only in hedging mode.
bool CanTrade = false;

ENUM_SYMBOL_TRADE_EXECUTION Execution_Mode;

int SlowMA;
int FastMA;

int myMA1, myMA2;

int OnInit()
{
    FastMA = MathMin(Period_1, Period_2);
    SlowMA = MathMax(Period_1, Period_2);

    if (FastMA == SlowMA)
    {
        Print("MA periods should differ.");
        return INIT_FAILED;
    }

    Poin = _Point;
    Deviation = Slippage;
    // Checking for unconventional Point digits number.
    if ((_Point == 0.00001) || (_Point == 0.001))
    {
        Poin *= 10;
        Deviation *= 10;
    }

    Trade = new CTrade;
    Trade.SetDeviationInPoints(Deviation);
    Magic = PeriodSeconds() + 19472394; // Will work only in hedging mode.
    Trade.SetExpertMagicNumber(Magic);

    myMA1 = iMA(NULL, 0, FastMA, 0, MA_Method, PRICE_CLOSE);
    myMA2 = iMA(NULL, 0, SlowMA, 0, MA_Method, PRICE_CLOSE);
    
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    delete Trade;
}

void OnTick()
{
    Execution_Mode = (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_EXEMODE);
    if (Execution_Mode == SYMBOL_TRADE_EXECUTION_MARKET) DoSLTP(); // ECN mode - set SL and TP.

    CanTrade = CheckTime();

    if ((TrailingStop > 0) && ((CanTrade) || (DoTrailingOutsideTradingTime))) DoTrailing();

    // Wait for the new Bar in a chart.
    if (LastBars == Bars(_Symbol, _Period)) return;
    else LastBars = Bars(_Symbol, _Period);

    if ((Bars(_Symbol, _Period) < SlowMA) || (MQLInfoInteger(MQL_TRADE_ALLOWED) == false)) return;

    CheckCross();
}

//+------------------------------------------------------------------+
//| Check for cross and open/close the positions respectively.       |
//+------------------------------------------------------------------+
void CheckCross()
{
    double FMABuffer[], SMABuffer[];

    CopyBuffer(myMA1, 0, 1, 1, FMABuffer);
    CopyBuffer(myMA2, 0, 1, 1, SMABuffer);

    double FMA_Current = FMABuffer[0];
    double SMA_Current = SMABuffer[0];

    if (PrevCross == 0) // Was undefined.
    {
        if ((FMA_Current - SMA_Current) >= MinDiff * Poin) PrevCross = 1; // Bullish state.
        else if ((SMA_Current - FMA_Current) >= MinDiff * Poin) PrevCross = -1; // Bearish state.
        return;
    }
    else if (PrevCross == 1) // Was bullish.
    {
        if ((SMA_Current - FMA_Current) >= MinDiff * Poin) // Became bearish.
        {
            if ((CanTrade) || (CloseTradesOutsideTradingTime)) ClosePrev();
            if ((CanTrade) && (TradeDirection != TRADE_DIRECTION_LONG)) fSell();
            PrevCross = -1;
        }
    }
    else if (PrevCross == -1) // Was bearish.
    {
        if ((FMA_Current - SMA_Current) >= MinDiff * Poin) // Became bullish.
        {
            if ((CanTrade) || (CloseTradesOutsideTradingTime)) ClosePrev();
            if ((CanTrade) && (TradeDirection != TRADE_DIRECTION_SHORT)) fBuy();
            PrevCross = 1;
        }
    }
}

//+------------------------------------------------------------------+
//| Close previous position.                                         |
//+------------------------------------------------------------------+
void ClosePrev()
{
    // Closing positions if necessary.
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if (ticket <= 0)
        {
            int error = GetLastError();
            Print("PositionGetTicket failed " + IntegerToString(error) + ".");
            continue;
        }
        if (PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
        if (PositionGetInteger(POSITION_MAGIC) != Magic) continue;
        if (SymbolInfoInteger(PositionGetString(POSITION_SYMBOL), SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
        {
            Print("Trading disabled in symbol: " + PositionGetString(POSITION_SYMBOL) + ".");
            continue;
        }
        for (int j = 0; j < 10; j++)
        {
            if (Trade.PositionClose(ticket)) break;
            else Print("Failed to close position #", ticket, ", error: ", GetLastError());
        }
    }
}

//+------------------------------------------------------------------+
//| Sell                                                             |
//+------------------------------------------------------------------+
void fSell()
{
    double SL, TP;
    if (StopLoss > 0) SL = SymbolInfoDouble(Symbol(), SYMBOL_BID) + StopLoss * Poin;
    else SL = 0;
    if (TakeProfit > 0) TP = SymbolInfoDouble(Symbol(), SYMBOL_BID) - TakeProfit * Poin;
    else TP = 0;

    if (Execution_Mode != SYMBOL_TRADE_EXECUTION_MARKET)
    {
        SL = NormalizeDouble(SL, _Digits);
        TP = NormalizeDouble(TP, _Digits);
    }
    else
    {
        SL = 0;
        TP = 0;
    }

    for (int i = 0; i < 10; i++)
    {
        if (!Trade.Sell(LotsOptimized(), Symbol(), NormalizeDouble(SymbolInfoDouble(Symbol(), SYMBOL_BID), _Digits), SL, TP, OrderCommentary))
        {
            Print("Error sending order: " + Trade.ResultRetcodeDescription() + ".");
        }
        else break;
    }
}

//+------------------------------------------------------------------+
//| Buy                                                              |
//+------------------------------------------------------------------+
void fBuy()
{
    double SL, TP;
    if (StopLoss > 0) SL = SymbolInfoDouble(Symbol(), SYMBOL_ASK) - StopLoss * Poin;
    else SL = 0;
    if (TakeProfit > 0) TP = SymbolInfoDouble(Symbol(), SYMBOL_ASK) + TakeProfit * Poin;
    else TP = 0;

    if (Execution_Mode != SYMBOL_TRADE_EXECUTION_MARKET)
    {
        SL = NormalizeDouble(SL, _Digits);
        TP = NormalizeDouble(TP, _Digits);
    }
    else
    {
        SL = 0;
        TP = 0;
    }

    for (int i = 0; i < 10; i++)
    {
        if (!Trade.Buy(LotsOptimized(), Symbol(), NormalizeDouble(SymbolInfoDouble(Symbol(), SYMBOL_ASK), _Digits), SL, TP, OrderCommentary))
        {
            Print("Error sending order: " + Trade.ResultRetcodeDescription() + ".");
        }
        else break;
    }
}

void DoTrailing()
{
    // Modifying SL if necessary.
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if (ticket <= 0)
        {
            int error = GetLastError();
            Print("PositionGetTicket failed " + IntegerToString(error) + ".");
            continue;
        }
        if (PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
        if (PositionGetInteger(POSITION_MAGIC) != Magic) continue;
        if (SymbolInfoInteger(PositionGetString(POSITION_SYMBOL), SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
        {
            Print("Trading disabled in symbol: " + PositionGetString(POSITION_SYMBOL) + ".");
            continue;
        }

        // If the open position is Long.
        if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
            // If profit is greater or equal to the desired Trailing Stop value.
            if (SymbolInfoDouble(Symbol(), SYMBOL_BID) - PositionGetDouble(POSITION_PRICE_OPEN) >= TrailingStop * Poin)
            {
                if ((SymbolInfoDouble(Symbol(), SYMBOL_BID) - TrailingStop * Poin) - PositionGetDouble(POSITION_SL) > Point() / 2) // Double-safe comparison.
                {
                    double SL = NormalizeDouble(SymbolInfoDouble(Symbol(), SYMBOL_BID) - TrailingStop * Poin, _Digits);
                    double TP = PositionGetDouble(POSITION_TP);
                    Trade.PositionModify(ticket, SL, TP);
                }
            }
        }
        // If it is Short.
        else
        {
            // If profit is greater or equal to the desired Trailing Stop value.
            if (PositionGetDouble(POSITION_PRICE_OPEN) - SymbolInfoDouble(Symbol(), SYMBOL_ASK) >= TrailingStop * Poin)
            {
                if ((PositionGetDouble(POSITION_SL) - (SymbolInfoDouble(Symbol(), SYMBOL_ASK) + TrailingStop * Poin) > Point() / 2) || (PositionGetDouble(POSITION_SL) == 0)) // Double-safe comparison.
                {
                    double SL = NormalizeDouble(SymbolInfoDouble(Symbol(), SYMBOL_ASK) + TrailingStop * Poin, _Digits);
                    double TP = PositionGetDouble(POSITION_TP);
                    Trade.PositionModify(ticket, SL, TP);
                }
            }
        }
    }
}

double LotsOptimized()
{
    if (!UseMM) return Lots;
    double vol = NormalizeDouble((AccountInfoDouble(ACCOUNT_MARGIN_FREE) / 10000) * LotsPer10000, 1);
    if (vol <= 0) return Lots;
    return vol;
}

//+------------------------------------------------------------------+
//| Applies SL and TP to open positions if ECN mode is on.           |
//+------------------------------------------------------------------+
void DoSLTP()
{
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if (ticket <= 0)
        {
            int error = GetLastError();
            Print("PositionGetTicket failed " + IntegerToString(error) + ".");
            continue;
        }
        if (PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
        if (PositionGetInteger(POSITION_MAGIC) != Magic) continue;
        if (SymbolInfoInteger(PositionGetString(POSITION_SYMBOL), SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
        {
            Print("Trading disabled in symbol: " + PositionGetString(POSITION_SYMBOL) + ".");
            continue;
        }

        double SL = 0, TP = 0;

        if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
            if (StopLoss > 0) SL = NormalizeDouble(PositionGetDouble(POSITION_PRICE_OPEN) - StopLoss * Poin, _Digits);
            if (TakeProfit > 0) TP = NormalizeDouble(PositionGetDouble(POSITION_PRICE_OPEN) + TakeProfit * Poin, _Digits);
        }
        if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
        {
            if (StopLoss > 0) SL = NormalizeDouble(PositionGetDouble(POSITION_PRICE_OPEN) + StopLoss * Poin, _Digits);
            if (TakeProfit > 0) TP = NormalizeDouble(PositionGetDouble(POSITION_PRICE_OPEN) - TakeProfit * Poin, _Digits);
        }

        if (((PositionGetDouble(POSITION_SL) != SL) || (PositionGetDouble(POSITION_TP) != TP)) && (PositionGetDouble(POSITION_SL) == 0) && (PositionGetDouble(POSITION_TP) == 0))
        {
            Trade.PositionModify(_Symbol, SL, TP);
        }
    }
}

bool CheckTime()
{
    if ((TimeCurrent() >= StringToTime(StartTime)) && (TimeCurrent() <= StringToTime(EndTime) + 59)) // Using +59 seconds to make the minute time inclusive.
    {
        return true;
    }
    return false;
}
//+------------------------------------------------------------------+