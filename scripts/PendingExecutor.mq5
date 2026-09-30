//+------------------------------------------------------------------+
//|                                  scripts/PendingExecutor.mq5      |
//|  Manual helper: executes one command line from the confirm file  |
//|  (or directly via the command input). Used with                 |
//|  InpConfirmMode=true to approve OpenAI trade requests.           |
//|                                                                  |
//|  Command format (pipe-separated):                               |
//|    open|SYMBOL|DIR|LOT|SL_PTS|TP_PTS|COMMENT                     |
//|    close|TICKET|VOLUME                                           |
//|    closeall|SYMBOL                                               |
//|  Returns the trade result to the log.                            |
//+------------------------------------------------------------------+
#property copyright "MQL5-OpenAI"
#property version   "1.00"
#property strict

#include <MT5Toolbox.mqh>
#include <Config.mqh>

input string InpCommand    = "";      // command line, e.g. "open|EURUSD|0|0.1|200|400|ai"
input string InpConfirmFile= "OpenAIBot\\confirm.txt"; // confirm file
input int    InpMagic      = 20261030;

//+------------------------------------------------------------------+
void OnStart(void)
  {
   string cmd=InpCommand;
   if(cmd=="")
     {
      // take the first line from the confirm file
      int h=FileOpen(InpConfirmFile,FILE_READ|FILE_TXT|FILE_ANSI);
      if(h==INVALID_HANDLE)
        {
         Print("PendingExecutor: no command and cannot read ",InpConfirmFile);
         return;
        }
      cmd=FileReadString(h);
      FileClose(h);
      // remove the executed line from the file
      RewriteConfirmFile(cmd);
     }
   if(cmd=="")
     {
      Print("PendingExecutor: empty command");
      return;
     }

   // parse pipe-separated
   string parts[];
   int n=StringSplit(cmd,'|',parts);
   if(n<2)
     {
      Print("PendingExecutor: bad command: ",cmd);
      return;
     }
   string op=parts[0];
   StringToLower(op);
   StringTrimLeft(op);
   StringTrimRight(op);

   SGuardSettings g;
   g.magic=InpMagic;
   CMT5Toolbox tb;
   tb.SetGuard(g);
   tb.SetLogFile("OpenAIBot\\log.txt");

   string result="";
   if(op=="open")
     {
      if(n<4){ Print("open needs: open|SYMBOL|DIR|LOT [|SL|TP|COMMENT]"); return; }
      string sym=parts[1];
      int dir=(int)StringToInteger(parts[2]);
      double lot=StringToDouble(parts[3]);
      double sl= (n>4)?StringToDouble(parts[4]):0;
      double tp= (n>5)?StringToDouble(parts[5]):0;
      string comment=(n>6)?parts[6]:"OpenAI-manual";
      result=tb.ToolOpenOrder(sym,dir,lot,sl,tp,comment);
     }
   else if(op=="close")
     {
      if(n<3){ Print("close needs: close|TICKET|VOLUME"); return; }
      long ticket=StringToInteger(parts[1]);
      double vol=(n>2)?StringToDouble(parts[2]):0;
      result=tb.ToolClosePosition("",ticket,vol);
     }
   else if(op=="closeall")
     {
      string sym=(n>1)?parts[1]:"";
      result=tb.ToolCloseAll(sym);
     }
   else
     {
      Print("PendingExecutor: unknown op: ",op);
      return;
     }
   Print("PendingExecutor: ",cmd," => ",result);
  }

//+------------------------------------------------------------------+
void RewriteConfirmFile(const string skipLine)
  {
   string remaining="";
   int h=FileOpen(InpConfirmFile,FILE_READ|FILE_TXT|FILE_ANSI);
   if(h!=INVALID_HANDLE)
     {
      while(!FileIsEnding(h))
        {
         string line=FileReadString(h);
         StringTrimRight(line);
         if(line=="" || line==skipLine) continue;
         remaining+=line+"\r\n";
        }
      FileClose(h);
     }
   int w=FileOpen(InpConfirmFile,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(w!=INVALID_HANDLE)
     {
      if(remaining!="") FileWriteString(w,remaining);
      FileClose(w);
     }
  }
//+------------------------------------------------------------------+
