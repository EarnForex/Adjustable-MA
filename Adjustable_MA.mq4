//+------------------------------------------------------------------+
//|                                        Adjustable Moving Average |
//|                             Copyright © 2009-2026, EarnForex.com |
//|                                       https://www.earnforex.com/ |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2009-2026, EarnForex"
#property link      "https://www.earnforex.com/metatrader-expert-advisors/Adjustable-MA/"
#property version   "1.08"
#property strict

#property description "Adjustable MA EA - expert advisor for customizable MA trading."
#property description "Modify StopLoss, TakeProfit, TrailingStop, MA Period, MA Type,"
#property description "and minimum difference between MAs to count as cross."

enum ENUM_TRADE_DIRECTION
{
    TRADE_DIRECTION_LONG, // Long-only
    TRADE_DIRECTION_SHORT, // Short-only
    TRADE_DIRECTION_BOTH, // Both
    TRADE_DIRECTION_NONE // None (trailing and closing only)
};

input group "Main"
input int Period_1 = 20;
input int Period_2 = 22;
input ENUM_MA_METHOD MA_Method_Fast = MODE_EMA;
input ENUM_MA_METHOD MA_Method_Slow = MODE_EMA;
input ENUM_APPLIED_PRICE MA_Price_Fast = PRICE_CLOSE;
input ENUM_APPLIED_PRICE MA_Price_Slow = PRICE_CLOSE;
input int MinDiff = 30; // MinDiff: Minimum difference in points between MAs
input int StopLoss = 0; // Stop-loss in points
input int TakeProfit = 0; // Take-profit in points
input int TrailingStop = 0; // Trailing stop in points
input int TrailingStopTriggerProfit = 0; // TrailingStopTriggerProfit: Profit in points to start trailing. 0 = start immediately.
input ENUM_TRADE_DIRECTION TradeDirection = TRADE_DIRECTION_BOTH;
input group "Time management"
input int StartHour =    0; // Start hour (Server), inclusive, 0-23
input int StartMinute =  0; // Start minute, 0-59
input int EndHour =     23; // End hour (Server), inclusive, 0-23
input int EndMinute =   59; // End minute, 0-59
input bool TradeOnMonday    = true;
input bool TradeOnTuesday   = true;
input bool TradeOnWednesday = true;
input bool TradeOnThursday  = true;
input bool TradeOnFriday    = true;
input bool TradeOnSaturday  = true;
input bool TradeOnSunday    = true;
input bool CloseTradesOutsideTradingTime = true;
input bool DoTrailingOutsideTradingTime = true;
input group "Money management"
input double Lots = 0.1;
input bool UseMM = false;
input double LotsPer10000 = 1; // LotsPer10000: Number of lots per every 10,000 of free margin.
input group "Miscellaneous"
input int Slippage = 30;
input string OrderCommentary = "Adjustable MA";
input bool DisplayStatusComment = false; // Display comment-based status?
input int Magic = 19472394;

int LastBars = 0;

// 0 - undefined, 1 - bullish cross (fast MA above slow MA), -1 - bearish cross (fast MA below slow MA).
int PrevCross = 0;

bool CanTrade = false;

ENUM_SYMBOL_TRADE_EXECUTION Execution_Mode;

int SlowMA;
int FastMA;

// Cached next state-change of the trading window, for the on-chart panel.
datetime CachedNextChange = 0;
datetime CachedComputedAt = 0;

int OnInit()
{
    FastMA = MathMin(Period_1, Period_2);
    SlowMA = MathMax(Period_1, Period_2);

    if (FastMA == SlowMA)
    {
        Print("MA periods should differ. Period_1 = Period_2 = ", Period_2, ".");
        return INIT_FAILED;
    }
    if (TrailingStopTriggerProfit < 0)
    {
        Print("TrailingStopTriggerProfit cannot be negative. Value = ", TrailingStopTriggerProfit, ".");
        return INIT_FAILED;
    }
    if ((StartHour < 0) || (StartHour > 23) || (EndHour < 0) || (EndHour > 23))
    {
        Print("Hour values must be between 0 and 23. StartHour = ", StartHour, ", EndHour = ", EndHour, ".");
        return INIT_FAILED;
    }
    if ((StartMinute < 0) || (StartMinute > 59) || (EndMinute < 0) || (EndMinute > 59))
    {
        Print("Minute values must be between 0 and 59. StartMinute = ", StartMinute, ", EndMinute = ", EndMinute, ".");
        return INIT_FAILED;
    }

    if (!UseMM)
    {
        double LotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
        double LotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        double LotMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
        if (Lots < LotMin)
        {
            Print("Lots (", Lots, ") is below broker minimum (", LotMin, ").");
            return INIT_FAILED;
        }
        if (Lots > LotMax)
        {
            Print("Lots (", Lots, ") exceeds broker maximum (", LotMax, ").");
            return INIT_FAILED;
        }
        double steps = Lots / LotStep;
        if (MathAbs(MathRound(steps) - steps) > 0.00000001)
        {
            Print("Lots (", Lots, ") is not a multiple of broker lot step (", LotStep, ").");
            return INIT_FAILED;
        }
    }

    if (DisplayStatusComment)
    {
        EventSetTimer(1);
        // Reset on re-init.
        CachedNextChange = 0;
        CachedComputedAt = 0;
    }

    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if (DisplayStatusComment) Comment("");
}

//+------------------------------------------------------------------+
//| Returns true if no time/weekday filtering is configured.         |
//+------------------------------------------------------------------+
bool NoTimeLimits()
{
    return ((StartHour == 0) && (StartMinute == 0) && (EndHour == 23) && (EndMinute == 59)
        && (TradeOnMonday) && (TradeOnTuesday) && (TradeOnWednesday) && (TradeOnThursday)
        && (TradeOnFriday) && (TradeOnSaturday) && (TradeOnSunday));
}

//+------------------------------------------------------------------+
//| Computes the next moment when the trading window state flips.    |
//| Returns 0 if no change happens within the next 8 days.           |
//|                                                                  |
//| State only changes at three kinds of moments within any day:     |
//|   - 00:00 (weekday transitions enable/disable the day)           |
//|   - StartHour:StartMinute (window opens, if day is enabled)      |
//|   - EndHour:EndMinute + 1 minute (window closes)                 |
//| We walk forward day by day, checking that day's boundaries in    |
//| chronological order, and return as soon as state actually flips. |
//+------------------------------------------------------------------+
datetime FindNextStateChange()
{
    datetime now = TimeCurrent();
    bool currentState = IsTradingTime(now);

    MqlDateTime ts;
    TimeToStruct(now, ts);
    ts.hour = 0;
    ts.min = 0;
    ts.sec = 0;
    datetime todayMidnight = StructToTime(ts);

    int startMin = StartHour * 60 + StartMinute;
    int endPlusOneMin = EndHour * 60 + EndMinute + 1; // Can equal 1440, naturally rolls into next-day midnight.

    for (int dayOffset = 0; dayOffset < 8; dayOffset++)
    {
        datetime base = todayMidnight + dayOffset * 86400;

        // Build this day's candidates in chronological order. At most 3.
        datetime dayCandidates[3];
        int n = 0;

        if (dayOffset > 0) dayCandidates[n++] = base; // Midnight (weekday transition).

        datetime openT = base + startMin * 60;
        datetime closeT = base + endPlusOneMin * 60;
        // For a same-day window startMin <= endMin, so openT <= closeT.
        // For a midnight-crossing window startMin > endMin, so closeT < openT.
        if (openT <= closeT)
        {
            dayCandidates[n++] = openT;
            dayCandidates[n++] = closeT;
        }
        else
        {
            dayCandidates[n++] = closeT;
            dayCandidates[n++] = openT;
        }

        for (int i = 0; i < n; i++)
        {
            if (dayCandidates[i] <= now) continue;
            if (IsTradingTime(dayCandidates[i]) != currentState) return dayCandidates[i];
        }
    }
    return 0; // Window is always open or always closed within scan horizon.
}

//+------------------------------------------------------------------+
//| Updates the on-chart status panel via Comment().                 |
//+------------------------------------------------------------------+
void UpdatePanel()
{
    datetime now = TimeCurrent();
    bool noLimits = NoTimeLimits();

    // Recompute the cached transition when stale or already reached.
    // Skip entirely when there are no time limits — nothing to display.
    if (!noLimits)
    {
        if ((CachedNextChange == 0) || (now >= CachedNextChange) || ((now - CachedComputedAt) >= 60))
        {
            CachedNextChange = FindNextStateChange();
            CachedComputedAt = now;
        }
    }

    string crossState;
    if (PrevCross == 1) crossState = "Bullish (fast above slow)";
    else if (PrevCross == -1) crossState = "Bearish (fast below slow)";
    else crossState = "Undefined (waiting for first cross)";

    // FMA - SMA difference at the closed bar, in points.
    double fma = iMA(NULL, 0, FastMA, 0, MA_Method_Fast, MA_Price_Fast, 1);
    double sma = iMA(NULL, 0, SlowMA, 0, MA_Method_Slow, MA_Price_Slow, 1);
    int diffPts = (int)MathRound((fma - sma) / _Point);
    string diffLine = "FMA(" + IntegerToString(FastMA) + ") - SMA(" + IntegerToString(SlowMA) + ") = " + IntegerToString(diffPts) + " pts";

    string dirLine = "";
    if (TradeDirection == TRADE_DIRECTION_LONG) dirLine = "\nDirection: Long only";
    else if (TradeDirection == TRADE_DIRECTION_SHORT) dirLine = "\nDirection: Short only";
    else if (TradeDirection == TRADE_DIRECTION_NONE) dirLine = "\nDirection: Closing and trailing only";

    string timeLine = "";
    if (!noLimits)
    {
        bool tradingNow = IsTradingTime(now);
        timeLine = tradingNow ? "\nTrading: ALLOWED" : "\nTrading: Outside Allowed Time Periods";

        if (CachedNextChange == 0)
        {
            timeLine += tradingNow ? "\nTrading is always allowed" : "\nTrading is never allowed (check weekday/time settings)";
        }
        else
        {
            string label = tradingNow ? "\nAllowed trading period ends at: " : "\nAllowed trading period starts at: ";
            timeLine += label + TimeToString(CachedNextChange, TIME_DATE | TIME_MINUTES);
        }
    }

    Comment(
        "Adjustable MA (Magic: ", Magic, ")\n",
        "Prev cross: ", crossState, "\n",
        diffLine,
        timeLine,
        dirLine);
}

void OnTimer()
{
    UpdatePanel();
}

void OnTick()
{
    CanTrade = CheckTime();

    if (PrevCross == 0) InitPrevCross(); // Was undefined.

    if (DisplayStatusComment) UpdatePanel();

    if ((TrailingStop > 0) && ((CanTrade) || (DoTrailingOutsideTradingTime))) DoTrailing();

    // Wait for the new Bar in a chart.
    if (LastBars == Bars) return;
    else LastBars = Bars;

    if ((Bars < SlowMA) || (IsTradeAllowed() == false)) return;

    Execution_Mode = (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_EXEMODE);

    CheckCross();
}

//+------------------------------------------------------------------+
//| Scan MAs back in time to determine the prior cross state.        |
//+------------------------------------------------------------------+
void InitPrevCross()
{
    // Start from bar index 2 and go back to find the most recent definitive MA state.
    for (int i = 2; i < Bars; i++)
    {
        double fma = iMA(NULL, 0, FastMA, 0, MA_Method_Fast, MA_Price_Fast, i);
        double sma = iMA(NULL, 0, SlowMA, 0, MA_Method_Slow, MA_Price_Slow, i);

        if (fma - sma >= MinDiff * _Point)
        {
            PrevCross = 1; // Bullish state found.
            return;
        }
        if (sma - fma >= MinDiff * _Point)
        {
            PrevCross = -1; // Bearish state found.
            return;
        }
    }
    // PrevCross remains 0 if no definitive state found.
}

//+------------------------------------------------------------------+
//| Check for cross and open/close the positions respectively.       |
//+------------------------------------------------------------------+
void CheckCross()
{
    double FMA_Current = iMA(NULL, 0, FastMA, 0, MA_Method_Fast, MA_Price_Fast, 1);
    double SMA_Current = iMA(NULL, 0, SlowMA, 0, MA_Method_Slow, MA_Price_Slow, 1);

    if (PrevCross == 0) return; // No definitive MA state found in history.

    if (PrevCross == 1) // Was bullish.
    {
        if (SMA_Current - FMA_Current >= MinDiff * _Point) // Became bearish.
        {
            if (CanTrade || CloseTradesOutsideTradingTime) ClosePrev();
            if (CanTrade && TradeDirection != TRADE_DIRECTION_LONG && TradeDirection != TRADE_DIRECTION_NONE) fSell();
            PrevCross = -1;
        }
    }
    else if (PrevCross == -1) // Was bearish.
    {
        if (FMA_Current - SMA_Current >= MinDiff * _Point) // Became bullish.
        {
            if (CanTrade || CloseTradesOutsideTradingTime) ClosePrev();
            if (CanTrade && TradeDirection != TRADE_DIRECTION_SHORT && TradeDirection != TRADE_DIRECTION_NONE) fBuy();
            PrevCross = 1;
        }
    }
}

//+------------------------------------------------------------------+
//| Close previous position.                                         |
//+------------------------------------------------------------------+
void ClosePrev()
{
    int total = OrdersTotal();
    for (int i = total - 1; i >= 0; i--)
    {
        if (OrderSelect(i, SELECT_BY_POS) == false) continue;
        if ((OrderSymbol() == Symbol()) && (OrderMagicNumber() == Magic))
        {
            if (OrderType() == OP_BUY)
            {
                // 10 attempts to close.
                for (int j = 0; j < 10; j++)
                {
                    RefreshRates();
                    if (OrderClose(OrderTicket(), OrderLots(), Bid, Slippage)) break;
                    else Print("Failed to close a Buy order #", OrderTicket(), " at Bid = ", Bid, ", Lots = ", OrderLots(), ", error: ", GetLastError());
                }
            }
            else if (OrderType() == OP_SELL)
            {
                // 10 attempts to close.
                for (int j = 0; j < 10; j++)
                {
                    RefreshRates();
                    if (OrderClose(OrderTicket(), OrderLots(), Ask, Slippage)) break;
                    else Print("Failed to close a Sell order #", OrderTicket(), " at Ask = ", Ask, ", Lots = ", OrderLots(), ", error: ", GetLastError());
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Sell                                                             |
//+------------------------------------------------------------------+
int fSell()
{
    double SL = 0, TP = 0;

    for (int i = 0; i < 10; i++)
    {
        RefreshRates();
        if (Execution_Mode != SYMBOL_TRADE_EXECUTION_MARKET)
        {
            if (StopLoss > 0) SL = Bid + StopLoss * _Point;
            if (TakeProfit > 0) TP = Bid - TakeProfit * _Point;
        }
        int result = OrderSend(Symbol(), OP_SELL, LotsOptimized(), Bid, Slippage, SL, TP, OrderCommentary, Magic);
    
        if (result == -1)
        {
            int e = GetLastError();
            Print("Sell OrderSend error: ", e, ". Price = ", Bid, ", Lots = ", LotsOptimized(), ", SL = ", SL, ", TP = ", TP, ".");
        }
        else
        {
            if (Execution_Mode == SYMBOL_TRADE_EXECUTION_MARKET)
            {
                RefreshRates();
                if (!OrderSelect(result, SELECT_BY_TICKET))
                {
                    Print("Failed to select a Sell order #", result, " for post-open SL/TP application, error: ", GetLastError());
                    return -1;
                }
                if (StopLoss > 0) SL = OrderOpenPrice() + StopLoss * _Point;
                if (TakeProfit > 0) TP = OrderOpenPrice() - TakeProfit * _Point;
                if ((SL != 0) || (TP != 0))
                {
                    if (!OrderModify(result, OrderOpenPrice(), SL, TP, 0))
                    {
                        Print("Failed to modify a Sell order #", result, " (applying post-open SL/TP). SL = ", SL, ", TP = ", TP, ", error: ", GetLastError());
                        return -1;
                    }
                }
            }
            return result;
        }
    }
    return -1;
}

//+------------------------------------------------------------------+
//| Buy                                                              |
//+------------------------------------------------------------------+
int fBuy()
{
    double SL = 0, TP = 0;

    for (int i = 0; i < 10; i++)
    {
        RefreshRates();
        if (Execution_Mode != SYMBOL_TRADE_EXECUTION_MARKET)
        {
            if (StopLoss > 0) SL = Ask - StopLoss * _Point;
            if (TakeProfit > 0) TP = Ask + TakeProfit * _Point;
        }
        int result = OrderSend(Symbol(), OP_BUY, LotsOptimized(), Ask, Slippage, SL, TP, OrderCommentary, Magic);
    
        if (result == -1)
        {
            int e = GetLastError();
            Print("Buy OrderSend error: ", e, ". Price = ", Ask, ", Lots = ", LotsOptimized(), ", SL = ", SL, ", TP = ", TP, ".");
        }
        else
        {
            if (Execution_Mode == SYMBOL_TRADE_EXECUTION_MARKET)
            {
                RefreshRates();
                if (!OrderSelect(result, SELECT_BY_TICKET))
                {
                    Print("Failed to select a Buy order #", result, " for post-open SL/TP application, error: ", GetLastError());
                    return -1;
                }
                if (StopLoss > 0) SL = OrderOpenPrice() - StopLoss * _Point;
                if (TakeProfit > 0) TP = OrderOpenPrice() + TakeProfit * _Point;
                if ((SL != 0) || (TP != 0))
                {
                    if (!OrderModify(result, OrderOpenPrice(), SL, TP, 0))
                    {
                        Print("Failed to modify a Buy order #", result, " (applying post-open SL/TP). SL = ", SL, ", TP = ", TP, ", error: ", GetLastError());
                        return -1;
                    }
                }
            }
            return result;
        }
    }
    return -1;
}

void DoTrailing()
{
    // Profit threshold at which trailing becomes active.
    // If TrailingStopTriggerProfit is 0, fall back to TrailingStop to preserve the original behavior.
    int TriggerDistance = (TrailingStopTriggerProfit > 0) ? TrailingStopTriggerProfit : TrailingStop;

    int total = OrdersTotal();
    for (int pos = 0; pos < total; pos++)
    {
        if (OrderSelect(pos, SELECT_BY_POS) == false) continue;
        if ((OrderMagicNumber() == Magic) && (OrderSymbol() == Symbol()))
        {
            if (OrderType() == OP_BUY)
            {
                RefreshRates();
                // If profit is greater or equal to the trigger profit value.
                if (Bid - OrderOpenPrice() >= TriggerDistance * _Point)
                {
                    // If the current stop-loss is below the desired trailing stop level.
                    if ((Bid - TrailingStop * _Point) - OrderStopLoss() > Point() / 2) // Double-safe comparison.
                        if (!OrderModify(OrderTicket(), OrderOpenPrice(), Bid - TrailingStop * _Point, OrderTakeProfit(), 0))
                            Print("Failed to modify a Buy order #", OrderTicket(), " (trailing stop). Attempted SL = ", Bid - TrailingStop * _Point, ", Bid = ", Bid, ", error: ", GetLastError());
                }
            }
            else if (OrderType() == OP_SELL)
            {
                RefreshRates();
                // If profit is greater or equal to the trigger profit value.
                if (OrderOpenPrice() - Ask >= TriggerDistance * _Point)
                {
                    // If the current stop-loss is below the desired trailing stop level.
                    if ((OrderStopLoss() - (Ask + TrailingStop * _Point) > Point() / 2) || (OrderStopLoss() == 0)) // Double-safe comparison.
                        if (!OrderModify(OrderTicket(), OrderOpenPrice(), Ask + TrailingStop * _Point, OrderTakeProfit(), 0))
                            Print("Failed to modify a Sell order #", OrderTicket(), " (trailing stop). Attempted SL = ", Ask + TrailingStop * _Point, ", Ask = ", Ask, ", error: ", GetLastError());
                }
            }
        }
    }
}

double LotsOptimized()
{
    if (!UseMM) return Lots;
    double vol = (AccountInfoDouble(ACCOUNT_MARGIN_FREE) / 10000) * LotsPer10000;

    double LotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);

    if (vol < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    else if (vol > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)) vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    double steps = vol / LotStep;
    if (MathAbs(MathRound(steps) - steps) > 0.00000001) vol = MathFloor(steps) * LotStep;

    return NormalizeDouble(vol, LotStep_digits);
}

//+------------------------------------------------------------------+
//| Returns true if the given time falls within an enabled window.   |
//+------------------------------------------------------------------+
bool IsTradingTime(datetime t)
{
    MqlDateTime time_struct;
    TimeToStruct(t, time_struct);

    // Weekday check. day_of_week: 0 = Sunday, 1 = Monday, ..., 6 = Saturday.
    switch (time_struct.day_of_week)
    {
        case 0: if (!TradeOnSunday)    return false; break;
        case 1: if (!TradeOnMonday)    return false; break;
        case 2: if (!TradeOnTuesday)   return false; break;
        case 3: if (!TradeOnWednesday) return false; break;
        case 4: if (!TradeOnThursday)  return false; break;
        case 5: if (!TradeOnFriday)    return false; break;
        case 6: if (!TradeOnSaturday)  return false; break;
    }

    int currentMinutes = time_struct.hour * 60 + time_struct.min;
    int startMinutes = StartHour * 60 + StartMinute;
    int endMinutes = EndHour * 60 + EndMinute;

    if (startMinutes <= endMinutes) // Same-day range.
    {
        if (currentMinutes >= startMinutes && currentMinutes <= endMinutes) return true;
    }
    else // Range crosses midnight.
    {
        if (currentMinutes >= startMinutes || currentMinutes <= endMinutes) return true;
    }
    return false;
}

bool CheckTime()
{
    return IsTradingTime(TimeCurrent());
}

//+------------------------------------------------------------------+
//| Counts decimal places.                                           |
//+------------------------------------------------------------------+
int CountDecimalPlaces(double number)
{
    // 100 as maximum length of number.
    for (int i = 0; i < 100; i++)
    {
        double pwr = MathPow(10, i);
        if (MathAbs(MathRound(number * pwr) / pwr - number) < 0.00000001) return i;
    }
    return -1;
}
//+------------------------------------------------------------------+