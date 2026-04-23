//+------------------------------------------------------------------+
//|                                                         RushX.mq5 |
//|                          Robô exclusivo ATA | Auto Trading Alliance|
//+------------------------------------------------------------------+
#property strict
#property version   "2.4"
#property description "RushX - Robô exclusivo da ATA | Auto Trading Alliance"
#property description "Desenvolvedor: Phelipe  |  +1 (385) 314-9098"
#property description "Todos os direitos reservados."

#include <Trade/Trade.mqh>

CTrade trade;

input group "=== Trade ==="
input double InpBaseLot                 = 0.01;     // Lote inicial
input int    InpGridStepPoints          = 300;      // Distância do grid (pontos)
input bool   InpUseMartingale           = true;     // Usar martingale
input double InpMartingaleMultiplier    = 1.5;      // Multiplicador martingale
input int    InpMaxOrders               = 10;       // Máximo de ordens por ciclo
input long   InpMagic                   = 26031201; // Magic number
input int    InpSlippagePoints          = 20;       // Slippage (pontos)
input int    InpMinSecondsBetweenGridOrders = 2;      // Antiduplicação: intervalo mínimo entre ordens de grid

input group "=== Alvos financeiros por cesta (sessão ativa) ==="
input double InpBasketTakeProfitMoney   = 10.0;     // TP da cesta (moeda da conta)
input double InpBasketStopLossMoney     = 20.0;     // SL da cesta (moeda da conta)

input group "=== Meta diária (lucro flutuante + fechado) ==="
input double InpDailyGainTargetMoney    = 100.0;    // Meta diária de ganho
input double InpDailyLossLimitMoney     = 100.0;    // Limite diário de perda (valor positivo)

input group "=== Janela de operação 1 (horário do servidor) ==="
input bool   InpUseTimeWindow1          = true;
input int    InpStartHour1              = 7;
input int    InpStartMinute1            = 0;
input int    InpEndHour1                = 15;
input int    InpEndMinute1              = 0;

input group "=== Janela de operação 2 (horário do servidor) ==="
input bool   InpUseTimeWindow2          = false;
input int    InpStartHour2              = 15;
input int    InpStartMinute2            = 0;
input int    InpEndHour2                = 23;
input int    InpEndMinute2              = 59;

const string             InpIndicatorName             = "Bull_Trend_Color";
const int                InpAMA_FastEMA               = 2;
const int                InpAMA_SlowEMA               = 30;
const ENUM_APPLIED_PRICE InpAppliedPrice              = PRICE_CLOSE;
const int                InpPeriodFast                = 9;
const int                InpPeriodMid                 = 20;
const int                InpPeriodSlow                = 200;
const color              InpBullColor                 = clrDodgerBlue;
const color              InpBearColor                 = clrRed;
const color              InpNeutralColor              = C'128,128,128';
const bool               InpColorCurrentBar           = false;
const int                InpRecalcLookback            = 0;
const bool               InpUseIndicatorFallback      = true;
const bool               InpShowColorIndicatorOnChart = true;
const bool               InpHideBuiltInMAsOnChart     = true;

enum TradeMode
{
   MODE_NONE = 0,
   MODE_BUY  = 1,
   MODE_SELL = 2
};

int      g_handle = INVALID_HANDLE;
int      g_visualHandle = INVALID_HANDLE;
int      g_amaFastHandle = INVALID_HANDLE;
int      g_amaMidHandle  = INVALID_HANDLE;
int      g_amaSlowHandle = INVALID_HANDLE;
bool     g_useInternalSignal = false;
datetime g_lastBarTime = 0;
datetime g_dayAnchor = 0;
bool     g_haltedToday = false;
TradeMode g_mode = MODE_NONE;
datetime g_lastGridOpenTime = 0;
double   g_lastGridOpenPrice = 0.0;
TradeMode g_lastGridOpenMode = MODE_NONE;

string TP_LINE_NAME = "RX_BASKET_TP";
string SL_LINE_NAME = "RX_BASKET_SL";

string ResolveIndicatorName()
{
   string name = InpIndicatorName;
   if(name == "" || name == "Bull Trend Color")
      name = "Bull_Trend_Color";
   return name;
}

void RemoveBuiltInMAsFromChart()
{
   if(!InpHideBuiltInMAsOnChart)
      return;

   int total = ChartIndicatorsTotal(0, 0);
   for(int i = total - 1; i >= 0; --i)
   {
      string indName = ChartIndicatorName(0, 0, i);
      if(indName == "")
         continue;

      bool isMA = (StringFind(indName, "Moving Average", 0) >= 0)
               || (StringFind(indName, "Adaptive Moving Average", 0) >= 0)
               || (StringFind(indName, "Média Móvel", 0) >= 0)
               || (StringFind(indName, "Adaptativa", 0) >= 0)
               || (StringFind(indName, "AMA", 0) >= 0);

      if(isMA)
         ChartIndicatorDelete(0, 0, indName);
   }
}

bool AttachColorIndicatorToChart()
{
   if(!InpShowColorIndicatorOnChart)
      return false;

   int visualHandle = iCustom(
      _Symbol,
      _Period,
      ResolveIndicatorName(),
      InpAMA_FastEMA,
      InpAMA_SlowEMA,
      InpAppliedPrice,
      InpPeriodFast,
      InpPeriodMid,
      InpPeriodSlow,
      InpBullColor,
      InpBearColor,
      InpNeutralColor,
      false,
      InpRecalcLookback
   );

   if(visualHandle == INVALID_HANDLE)
      return false;

   if(!ChartIndicatorAdd(0, 0, visualHandle))
   {
      IndicatorRelease(visualHandle);
      return false;
   }

   g_visualHandle = visualHandle;
   return true;
}

//+------------------------------------------------------------------+
int MinutesOfDay(const int hour,const int minute)
{
   return hour * 60 + minute;
}

bool IsInsideWindow(const int nowMins,const int startMins,const int endMins)
{
   if(startMins == endMins)
      return false;

   if(startMins < endMins)
      return (nowMins >= startMins && nowMins < endMins);

   return (nowMins >= startMins || nowMins < endMins);
}

bool IsTradingTime()
{
   if(!InpUseTimeWindow1 && !InpUseTimeWindow2)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMins = MinutesOfDay(dt.hour, dt.min);

   bool in1 = false;
   bool in2 = false;

   if(InpUseTimeWindow1)
      in1 = IsInsideWindow(nowMins, MinutesOfDay(InpStartHour1, InpStartMinute1), MinutesOfDay(InpEndHour1, InpEndMinute1));

   if(InpUseTimeWindow2)
      in2 = IsInsideWindow(nowMins, MinutesOfDay(InpStartHour2, InpStartMinute2), MinutesOfDay(InpEndHour2, InpEndMinute2));

   return (in1 || in2);
}

void UpdateDayAnchor()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime todayAnchor = StructToTime(dt);

   if(g_dayAnchor != todayAnchor)
   {
      g_dayAnchor = todayAnchor;
      g_haltedToday = false;
   }
}

bool IsNewBar()
{
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == 0)
      return false;

   if(t0 != g_lastBarTime)
   {
      g_lastBarTime = t0;
      return true;
   }

   return false;
}

double NormalizeVolume(double vol)
{
   double minVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   vol = MathMax(minVol, MathMin(maxVol, vol));

   if(stepVol > 0.0)
      vol = MathFloor(vol / stepVol) * stepVol;

   int digits = 2;
   if(stepVol > 0.0)
   {
      digits = 0;
      double tmp = stepVol;
      while(tmp < 1.0 && digits < 8)
      {
         tmp *= 10.0;
         digits++;
      }
   }

   return NormalizeDouble(vol, digits);
}

int CountPositions(const TradeMode mode)
{
   int c = 0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      if(mode == MODE_NONE)
      {
         c++;
         continue;
      }

      long ptype = PositionGetInteger(POSITION_TYPE);
      if(mode == MODE_BUY && ptype == POSITION_TYPE_BUY)
         c++;
      else if(mode == MODE_SELL && ptype == POSITION_TYPE_SELL)
         c++;
   }

   return c;
}

void UpdateModeFromPositions()
{
   int buys = CountPositions(MODE_BUY);
   int sells = CountPositions(MODE_SELL);

   if(buys > 0 && sells == 0)
      g_mode = MODE_BUY;
   else if(sells > 0 && buys == 0)
      g_mode = MODE_SELL;
   else if(buys == 0 && sells == 0)
      g_mode = MODE_NONE;
}

double BasketFloatingProfit()
{
   double total = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      total += PositionGetDouble(POSITION_PROFIT);
      total += PositionGetDouble(POSITION_SWAP);
   }

   return total;
}

double DailyClosedProfit()
{
   if(!HistorySelect(g_dayAnchor, TimeCurrent()))
      return 0.0;

   double p = 0.0;
   int total = HistoryDealsTotal();

   for(int i = 0; i < total; ++i)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0)
         continue;

      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol)
         continue;

      if((long)HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagic)
         continue;

      if((long)HistoryDealGetInteger(tk, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      p += HistoryDealGetDouble(tk, DEAL_PROFIT);
      p += HistoryDealGetDouble(tk, DEAL_SWAP);
      p += HistoryDealGetDouble(tk, DEAL_COMMISSION);
   }

   return p;
}

double DailyTotalProfitInclFloating()
{
   return DailyClosedProfit() + BasketFloatingProfit();
}

void DeleteLines()
{
   ObjectDelete(0, TP_LINE_NAME);
   ObjectDelete(0, SL_LINE_NAME);
}

void CreateOrMoveLine(const string name, const double price, const color clr)
{
   if(price <= 0.0)
      return;

   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   }

   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
}

void BasketAvgPriceAndVolume(const TradeMode mode,double &avgPrice,double &totalVol)
{
   avgPrice = 0.0;
   totalVol = 0.0;
   double pv = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      long ptype = PositionGetInteger(POSITION_TYPE);
      if(mode == MODE_BUY && ptype != POSITION_TYPE_BUY)
         continue;
      if(mode == MODE_SELL && ptype != POSITION_TYPE_SELL)
         continue;

      double vol = PositionGetDouble(POSITION_VOLUME);
      double op = PositionGetDouble(POSITION_PRICE_OPEN);

      pv += op * vol;
      totalVol += vol;
   }

   if(totalVol > 0.0)
      avgPrice = pv / totalVol;
}

void UpdateBasketLines()
{
   UpdateModeFromPositions();
   if(g_mode == MODE_NONE)
   {
      DeleteLines();
      return;
   }

   double avg = 0.0;
   double vol = 0.0;
   BasketAvgPriceAndVolume(g_mode, avg, vol);
   if(avg <= 0.0 || vol <= 0.0)
      return;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return;

   double valuePerPointPerLot = tickValue * (_Point / tickSize);
   if(valuePerPointPerLot <= 0.0)
      return;

   double tpPoints = 0.0;
   double slPoints = 0.0;

   if(InpBasketTakeProfitMoney > 0.0)
      tpPoints = InpBasketTakeProfitMoney / (valuePerPointPerLot * vol);

   if(InpBasketStopLossMoney > 0.0)
      slPoints = InpBasketStopLossMoney / (valuePerPointPerLot * vol);

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tpPrice = 0.0;
   double slPrice = 0.0;

   if(g_mode == MODE_BUY)
   {
      if(tpPoints > 0.0)
         tpPrice = NormalizeDouble(avg + tpPoints * _Point, digits);
      if(slPoints > 0.0)
         slPrice = NormalizeDouble(avg - slPoints * _Point, digits);
   }
   else if(g_mode == MODE_SELL)
   {
      if(tpPoints > 0.0)
         tpPrice = NormalizeDouble(avg - tpPoints * _Point, digits);
      if(slPoints > 0.0)
         slPrice = NormalizeDouble(avg + slPoints * _Point, digits);
   }

   if(tpPrice > 0.0)
      CreateOrMoveLine(TP_LINE_NAME, tpPrice, clrLime);
   if(slPrice > 0.0)
      CreateOrMoveLine(SL_LINE_NAME, slPrice, clrTomato);
}

bool CloseAllPositions()
{
   bool allClosed = true;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      if(!trade.PositionClose(tk, InpSlippagePoints))
         allClosed = false;
   }

   if(allClosed)
   {
      DeleteLines();
      g_mode = MODE_NONE;
   }

   return allClosed;
}

double LastEntryPrice(const TradeMode mode)
{
   datetime lastTime = 0;
   double lastPrice = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      long ptype = PositionGetInteger(POSITION_TYPE);
      if(mode == MODE_BUY && ptype != POSITION_TYPE_BUY)
         continue;
      if(mode == MODE_SELL && ptype != POSITION_TYPE_SELL)
         continue;

      datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(t >= lastTime)
      {
         lastTime = t;
         lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }

   return lastPrice;
}

double NextLot(const TradeMode mode)
{
   int count = CountPositions(mode);
   double lot = InpBaseLot;

   if(InpUseMartingale && count > 0)
      lot = InpBaseLot * MathPow(InpMartingaleMultiplier, count);

   return NormalizeVolume(lot);
}

bool OpenByMode(const TradeMode mode, const double lot)
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   if(mode == MODE_BUY)
      return trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, "RX_GRID_BUY");

   if(mode == MODE_SELL)
      return trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, "RX_GRID_SELL");

   return false;
}

bool CanOpenAnotherGridOrder(const TradeMode mode, const double marketPrice)
{
   if(InpMinSecondsBetweenGridOrders <= 0)
      return true;

   if(g_lastGridOpenMode != mode)
      return true;

   int secondsFromLast = (int)(TimeCurrent() - g_lastGridOpenTime);
   if(secondsFromLast >= InpMinSecondsBetweenGridOrders)
      return true;

   if(MathAbs(marketPrice - g_lastGridOpenPrice) > (_Point * 2.0))
      return true;

   return false;
}

void MarkGridOrderOpened(const TradeMode mode, const double marketPrice)
{
   g_lastGridOpenMode = mode;
   g_lastGridOpenTime = TimeCurrent();
   g_lastGridOpenPrice = marketPrice;
}

int ReadSignal()
{
   if(!g_useInternalSignal)
   {
      double val[];
      ArraySetAsSeries(val, true);

      int copied = CopyBuffer(g_handle, 4, 1, 1, val); // candle fechado
      if(copied >= 1)
         return (int)MathRound(val[0]); // 0=bull 1=bear 2=neutral

      if(!InpUseIndicatorFallback)
         return -1;

      g_useInternalSignal = true;
   }

   if(g_amaFastHandle == INVALID_HANDLE || g_amaMidHandle == INVALID_HANDLE || g_amaSlowHandle == INVALID_HANDLE)
      return -1;

   double a9[], a20[], a200[];
   ArraySetAsSeries(a9, true);
   ArraySetAsSeries(a20, true);
   ArraySetAsSeries(a200, true);

   if(CopyBuffer(g_amaFastHandle, 0, 1, 1, a9) < 1)
      return -1;
   if(CopyBuffer(g_amaMidHandle, 0, 1, 1, a20) < 1)
      return -1;
   if(CopyBuffer(g_amaSlowHandle, 0, 1, 1, a200) < 1)
      return -1;

   double c = iClose(_Symbol, _Period, 1);
   if(c <= 0.0)
      return -1;

   bool closeAboveAll = (c > a9[0] && c > a20[0] && c > a200[0]);
   bool closeBelowAll = (c < a9[0] && c < a20[0] && c < a200[0]);

   bool slowBelowFastMid = (a200[0] < a9[0] && a200[0] < a20[0]);
   bool slowAboveFastMid = (a200[0] > a9[0] && a200[0] > a20[0]);

   if(closeAboveAll && slowBelowFastMid)
      return 0;
   if(closeBelowAll && slowAboveFastMid)
      return 1;

   return 2;
}

bool HitBasketTargets()
{
   double basketPnl = BasketFloatingProfit();

   if(InpBasketTakeProfitMoney > 0.0 && basketPnl >= InpBasketTakeProfitMoney)
      return true;

   if(InpBasketStopLossMoney > 0.0 && basketPnl <= -InpBasketStopLossMoney)
      return true;

   return false;
}

bool HitDailyTargets()
{
   double dayPnl = DailyTotalProfitInclFloating();

   if(InpDailyGainTargetMoney > 0.0 && dayPnl >= InpDailyGainTargetMoney)
      return true;

   if(InpDailyLossLimitMoney > 0.0 && dayPnl <= -InpDailyLossLimitMoney)
      return true;

   return false;
}

int OnInit()
{
   g_useInternalSignal = false;

   g_handle = iCustom(
      _Symbol,
      _Period,
      ResolveIndicatorName(),
      InpAMA_FastEMA,
      InpAMA_SlowEMA,
      InpAppliedPrice,
      InpPeriodFast,
      InpPeriodMid,
      InpPeriodSlow,
      InpBullColor,
      InpBearColor,
      InpNeutralColor,
      false,
      InpRecalcLookback
   );

   if(g_handle == INVALID_HANDLE)
   {
      if(!InpUseIndicatorFallback)
         return INIT_FAILED;

      g_useInternalSignal = true;

      g_amaFastHandle = iAMA(_Symbol, _Period, InpPeriodFast, InpAMA_FastEMA, InpAMA_SlowEMA, 0, InpAppliedPrice);
      g_amaMidHandle  = iAMA(_Symbol, _Period, InpPeriodMid,  InpAMA_FastEMA, InpAMA_SlowEMA, 0, InpAppliedPrice);
      g_amaSlowHandle = iAMA(_Symbol, _Period, InpPeriodSlow, InpAMA_FastEMA, InpAMA_SlowEMA, 0, InpAppliedPrice);

      if(g_amaFastHandle == INVALID_HANDLE || g_amaMidHandle == INVALID_HANDLE || g_amaSlowHandle == INVALID_HANDLE)
         return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   RemoveBuiltInMAsFromChart();
   AttachColorIndicatorToChart();

   UpdateDayAnchor();
   UpdateModeFromPositions();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_handle != INVALID_HANDLE)
      IndicatorRelease(g_handle);
   if(g_visualHandle != INVALID_HANDLE)
      IndicatorRelease(g_visualHandle);
   if(g_amaFastHandle != INVALID_HANDLE)
      IndicatorRelease(g_amaFastHandle);
   if(g_amaMidHandle != INVALID_HANDLE)
      IndicatorRelease(g_amaMidHandle);
   if(g_amaSlowHandle != INVALID_HANDLE)
      IndicatorRelease(g_amaSlowHandle);

   DeleteLines();
}

void OnTick()
{
   static bool s_initCleanupDone = false;
   if(!s_initCleanupDone)
   {
      RemoveBuiltInMAsFromChart();
      s_initCleanupDone = true;
   }

   UpdateDayAnchor();
   UpdateModeFromPositions();

   // gestão de cesta sempre ativa enquanto houver posição
   if(CountPositions(MODE_NONE) > 0)
   {
      UpdateBasketLines();

      if(HitBasketTargets() || HitDailyTargets())
      {
         CloseAllPositions();
         UpdateModeFromPositions();
      }
   }

   // travamento diário após bater meta/limite
   if(HitDailyTargets())
   {
      g_haltedToday = true;
      return;
   }

   if(g_haltedToday)
      return;

   // fora do horário só não inicia/empilha novas ordens
   if(!IsTradingTime())
      return;

   int total = CountPositions(MODE_NONE);

   // Sem posição: entrada somente em candle fechado
   if(total == 0)
   {
      if(!IsNewBar())
         return;

      int sig = ReadSignal();
      if(sig == 0)
      {
         g_mode = MODE_BUY;
         if(OpenByMode(MODE_BUY, NextLot(MODE_BUY)))
         {
            MarkGridOrderOpened(MODE_BUY, SymbolInfoDouble(_Symbol, SYMBOL_ASK));
            UpdateBasketLines();
         }
      }
      else if(sig == 1)
      {
         g_mode = MODE_SELL;
         if(OpenByMode(MODE_SELL, NextLot(MODE_SELL)))
         {
            MarkGridOrderOpened(MODE_SELL, SymbolInfoDouble(_Symbol, SYMBOL_BID));
            UpdateBasketLines();
         }
      }

      return;
   }

   // Com posição: ignora cor e segue o modo até encerrar cesta
   if(g_mode != MODE_BUY && g_mode != MODE_SELL)
      return;

   int modeCount = CountPositions(g_mode);
   if(modeCount <= 0 || modeCount >= InpMaxOrders)
      return;

   double last = LastEntryPrice(g_mode);
   if(last <= 0.0)
      return;

   double step = InpGridStepPoints * _Point;
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool shouldOpen = false;
   if(g_mode == MODE_BUY)
      shouldOpen = (bid <= (last - step));
   else if(g_mode == MODE_SELL)
      shouldOpen = (ask >= (last + step));

   if(shouldOpen && CanOpenAnotherGridOrder(g_mode, (g_mode == MODE_BUY ? bid : ask)))
   {
      if(OpenByMode(g_mode, NextLot(g_mode)))
      {
         MarkGridOrderOpened(g_mode, (g_mode == MODE_BUY ? ask : bid));
         UpdateBasketLines();
      }
   }
}
//+------------------------------------------------------------------+
