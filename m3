//+------------------------------------------------------------------+
//|  XAUUSD_HF_Scalper.mq4                                           |
//|  Ported from Python Binance LSTM scalper -> lightweight MQL4 EA  |
//|  NOTE: This version includes broker compatibility fixes only.    |
//+------------------------------------------------------------------+
#property copyright "Converted by ChatGPT"
#property link      ""
#property version   "1.01"
#property strict

//--- INPUTS
input string TradeSymbol            = "XAUUSD";
input double TRADE_AMOUNT_USD       = 10.0;
input int    LEVERAGE               = 30;
input double MIN_NOTIONAL_USD       = 10.0;
input int    SEQ_LEN                = 20;
input int    FUTURE_STEP_FOR_LABEL  = 3;
input int    TRADE_HOLD_STEPS       = 1;
input double SLIPPAGE_POINTS        = 3;
input double MIN_INTERVAL_BETWEEN_ORDERS = 0.2;
input int    MAX_ORDERS_PER_MINUTE  = 80;
input double LotsMin                = 0.01;
input double LotsStep               = 0.01;
input int    PrintEveryTicks        = 1;

//--- internal globals
double midBuffer[];
int    bufIndex = 0;
int    bufCount = 0;

datetime orderTimestamps[200];
int      tsCount = 0;

struct OpenTrade {
  int    ticket;
  double entryPrice;
  string side;
  int    openedOnTick;
  double lots;
  double notional;
};
OpenTrade openTrades[];

string futurePreds[];
int tickIndex = 0;

int wins=0, losses=0;
double balance_at_start = 0.0;

double lastOrderTime = 0.0;

int accuracyBufferLen = 50;
int accuracyBuffer[];
int accIdx = 0, accCount = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   ArrayResize(midBuffer, SEQ_LEN);
   ArrayInitialize(midBuffer, 0.0);

   ArrayResize(orderTimestamps, MAX_ORDERS_PER_MINUTE + 5);
   ArrayInitialize(orderTimestamps, 0);

   ArrayResize(futurePreds, FUTURE_STEP_FOR_LABEL);
   for(int i=0; i<FUTURE_STEP_FOR_LABEL; i++) futurePreds[i] = "";

   ArrayResize(accuracyBuffer, accuracyBufferLen);
   ArrayInitialize(accuracyBuffer, 0);

   balance_at_start = AccountBalance();

   PrintFormat("[INIT] EA initialized for %s | TRADE_AMOUNT_USD=%.2f | LEVERAGE=%d",
               TradeSymbol, TRADE_AMOUNT_USD, LEVERAGE);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
bool RateLimiterWaitSlot()
{
   double now_sec = (double)TimeCurrent();

   if(now_sec - lastOrderTime < MIN_INTERVAL_BETWEEN_ORDERS)
      return(false);

   int keep=0;
   for(int i=0; i<tsCount; i++){
      if((double)orderTimestamps[i] >= (TimeCurrent() - 60))
         orderTimestamps[keep++] = orderTimestamps[i];
   }
   tsCount = keep;

   if(tsCount >= MAX_ORDERS_PER_MINUTE) return(false);

   orderTimestamps[tsCount++] = TimeCurrent();
   lastOrderTime = now_sec;
   return(true);
}

//+------------------------------------------------------------------+
// ✅ UPDATED: Contract size auto-detection (no logic changed otherwise)
double ComputeLots(double entryPrice)
{
   double contractSize = MarketInfo(TradeSymbol, MODE_LOTSIZE); // e.g., 100 or 1 depending on FBS account

   if(contractSize <= 0) contractSize = 100.0; // failsafe default

   double size_ounces = (TRADE_AMOUNT_USD * LEVERAGE) / entryPrice;
   double lots = size_ounces / contractSize;

   if(lots < LotsMin) return(0.0);
   int steps = (int)MathFloor(lots / LotsStep);
   double normLots = steps * LotsStep;
   if(normLots < LotsMin) return(0.0);
   return NormalizeDouble(normLots, 2);
}

//+------------------------------------------------------------------+
int PlaceMarketOrder(string side, double price, double lots, bool isExit=false)
{
   if(!RateLimiterWaitSlot())
   {
      Print("[RATE_LIMIT] blocked order");
      return(-1);
   }

   int slippage = (int)SLIPPAGE_POINTS;
   int ticket = -1;

   if(side == "UP")
   {
      double ask = MarketInfo(TradeSymbol, MODE_ASK);
      ticket = OrderSend(TradeSymbol, OP_BUY, lots, ask, slippage, 0, 0, "HF_EA", 0, 0, clrGreen);
   }
   else
   {
      double bid = MarketInfo(TradeSymbol, MODE_BID);
      ticket = OrderSend(TradeSymbol, OP_SELL, lots, bid, slippage, 0, 0, "HF_EA", 0, 0, clrRed);
   }

   if(ticket < 0)
      PrintFormat("[ERROR] OrderSend failed: %d - %s", GetLastError(), ErrorDescription(GetLastError()));

   return(ticket);
}

//+------------------------------------------------------------------+
string MakePrediction()
{
   if(bufCount < SEQ_LEN) return("DOWN");

   int ups=0, downs=0;
   for(int i = bufCount - FUTURE_STEP_FOR_LABEL; i < bufCount; i++)
   {
      double a = midBuffer[(i-1+SEQ_LEN)%SEQ_LEN];
      double b = midBuffer[(i+0)%SEQ_LEN];
      if(b > a) ups++; else downs++;
   }
   return(ups >= downs ? "UP" : "DOWN");
}

//+------------------------------------------------------------------+
void OnTick()
{
   static int debugCounter = 0;
   if(Symbol() != TradeSymbol) return;

   double bid = MarketInfo(TradeSymbol, MODE_BID);
   double ask = MarketInfo(TradeSymbol, MODE_ASK);
   if(bid <= 0 || ask <= 0) return;

   double mid = (bid + ask) / 2.0;

   midBuffer[bufIndex] = mid;
   bufIndex = (bufIndex + 1) % SEQ_LEN;
   if(bufCount < SEQ_LEN) bufCount++;

   tickIndex++;

   string pred = "";
   if(bufCount == SEQ_LEN)
   {
      pred = MakePrediction();
      for(int i=0;i<FUTURE_STEP_FOR_LABEL-1;i++) futurePreds[i]=futurePreds[i+1];
      futurePreds[FUTURE_STEP_FOR_LABEL-1] = pred;

      if(debugCounter % PrintEveryTicks == 0)
         PrintFormat("[%s] MADE_PRED tick=%d Pred=%s mid=%.5f",
                     TimeToString(TimeCurrent(), TIME_SECONDS), tickIndex, pred, mid);
   }

   bool have_future_preds = true;
   for(int i=0;i<FUTURE_STEP_FOR_LABEL;i++) if(futurePreds[i]=="") have_future_preds=false;

   if(have_future_preds)
   {
      int idx_past = (bufIndex - FUTURE_STEP_FOR_LABEL + SEQ_LEN) % SEQ_LEN;
      double mid_past = midBuffer[idx_past];
      string actual_dir = (mid > mid_past) ? "UP" : "DOWN";

      int correctCount=0;
      for(int i=0;i<FUTURE_STEP_FOR_LABEL;i++) if(futurePreds[i] == actual_dir) correctCount++;
      double correct = (double)correctCount / FUTURE_STEP_FOR_LABEL;

      int appendVal = (correct == 1.0) ? 1 : 0;
      accuracyBuffer[accIdx] = appendVal;
      accIdx = (accIdx + 1) % accuracyBufferLen;
      if(accCount < accuracyBufferLen) accCount++;

      int sumAcc=0;
      for(int i=0;i<accCount;i++) sumAcc += accuracyBuffer[i];
      double rollingAcc = accCount ? ((double)sumAcc / accCount) * 100.0 : 0.0;

      bool allAgree = true;
      for(int i=1;i<FUTURE_STEP_FOR_LABEL;i++) if(futurePreds[i] != futurePreds[0]) allAgree = false;

      if(allAgree && rollingAcc >= 50.0 && ArraySize(openTrades) == 0 && correct == 1.0)
      {
         string tradeSide = futurePreds[0];
         double entryPrice = mid;
         double notional = TRADE_AMOUNT_USD * LEVERAGE;

         if(notional >= MIN_NOTIONAL_USD)
         {
            double lots = ComputeLots(entryPrice);
            if(lots > 0.0)
            {
               int ticket = PlaceMarketOrder(tradeSide, entryPrice, lots, false);
               if(ticket > 0)
               {
                  OpenTrade t;
                  t.ticket = ticket;
                  t.entryPrice = entryPrice;
                  t.side = tradeSide;
                  t.openedOnTick = tickIndex;
                  t.lots = lots;
                  t.notional = notional;
                  ArrayResize(openTrades, ArraySize(openTrades) + 1);
                  openTrades[ArraySize(openTrades)-1] = t;

                  PrintFormat("💰 ENTER %s | $%.2f margin | notional=$%.2f @ %.5f lots=%.2f Bal=%.2f",
                              tradeSide, TRADE_AMOUNT_USD, notional, entryPrice, lots, AccountBalance());
               }
            }
         }
      }
   }

   if(ArraySize(openTrades) > 0)
   {
      int keepCount = 0;
      for(int i=0;i<ArraySize(openTrades);i++)
      {
         OpenTrade tr = openTrades[i];
         if(tickIndex >= tr.openedOnTick + TRADE_HOLD_STEPS)
         {
            if(OrderSelect(tr.ticket, SELECT_BY_TICKET))
            {
               double closePrice = (tr.side == "UP") ? MarketInfo(TradeSymbol, MODE_BID) : MarketInfo(TradeSymbol, MODE_ASK);
               bool ok = OrderClose(tr.ticket, tr.lots, closePrice, (int)SLIPPAGE_POINTS, clrYellow);

               double pnl = (tr.side == "UP") ?
                  ((closePrice - tr.entryPrice) / tr.entryPrice) * tr.notional :
                  ((tr.entryPrice - closePrice) / tr.entryPrice) * tr.notional;

               if(ok)
               {
                  if(pnl >= 0) { wins++; PrintFormat("🏆 WIN | %s | PnL=$%.2f | Bal=%.2f", tr.side, pnl, AccountBalance()); }
                  else { losses++; PrintFormat("💀 LOSS | %s | PnL=$%.2f | Bal=%.2f", tr.side, pnl, AccountBalance()); }
               }
            }
         }
         else
         {
            ArrayResize(openTrades, keepCount+1);
            openTrades[keepCount++] = tr;
         }
      }
      ArrayResize(openTrades, keepCount);
   }

   debugCounter++;
}

//+------------------------------------------------------------------+
string ErrorDescription(int code)
{
   switch(code)
   {
      case 1: return "No error returned";
      case 2: return "Common error";
      case 3: return "Invalid trade parameters";
      case 4: return "Trade server busy";
      case 6: return "No connection";
      case 8: return "Too frequent requests";
      default: return "ErrCode:" + IntegerToString(code);
   }
}
//+------------------------------------------------------------------+
