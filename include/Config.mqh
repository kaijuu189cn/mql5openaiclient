//+------------------------------------------------------------------+
//|                                             include/Config.mqh    |
//|  Tiny INI-style config loader (no external libs). File format:   |
//|     key = value                                                  |
//|  '#' or ';' starts a comment. Leading/trailing spaces trimmed.   |
//|  Values may be empty. Also provides a simple append log helper.  |
//+------------------------------------------------------------------+
#ifndef MQL5_OPENAI_CONFIG_MQH
#define MQL5_OPENAI_CONFIG_MQH

class CConfig
  {
private:
   string m_keys[];
   string m_vals[];

   static string Trim(const string s)
     {
      string t=s;
      StringTrimLeft(t);
      StringTrimRight(t);
      return t;
     }

public:
   CConfig(void){}

   bool Load(const string file)
     {
      ArrayResize(m_keys,0);
      ArrayResize(m_vals,0);
      int h=FileOpen(file,FILE_READ|FILE_TXT|FILE_ANSI);
      if(h==INVALID_HANDLE) return false;
      while(!FileIsEnding(h))
        {
         string line=FileReadString(h);
         // strip comments
         int ci=StringFind(line,";");
         if(ci<0) ci=StringFind(line,"#");
         if(ci>=0) line=StringSubstr(line,0,ci);
         string t=Trim(line);
         if(t=="") continue;
         int eq=StringFind(t,"=");
         if(eq<0) continue;   // skip lines without '='
         string k=Trim(StringSubstr(t,0,eq));
         string v=Trim(StringSubstr(t,eq+1));
         if(k=="") continue;
         int n=ArraySize(m_keys);
         ArrayResize(m_keys,n+1);
         ArrayResize(m_vals,n+1);
         m_keys[n]=k;
         m_vals[n]=v;
        }
      FileClose(h);
      return true;
     }

   bool Has(const string key) const
     {
      int n=ArraySize(m_keys);
      for(int i=0;i<n;i++)
         if(m_keys[i]==key) return true;
      return false;
     }

   string GetString(const string key,const string def="") const
     {
      int n=ArraySize(m_keys);
      for(int i=0;i<n;i++)
         if(m_keys[i]==key) return m_vals[i];
      return def;
     }

   int GetInt(const string key,const int def=0) const
     {
      string v=GetString(key,"");
      if(v=="") return def;
      return (int)StringToInteger(v);
     }

   double GetDouble(const string key,const double def=0.0) const
     {
      string v=GetString(key,"");
      if(v=="") return def;
      return StringToDouble(v);
     }

   bool GetBool(const string key,const bool def=false) const
     {
      string v=GetString(key,"");
      if(v=="") return def;
      StringToUpper(v);
      return (v=="1" || v=="true" || v=="yes" || v=="on");
     }
  };

//--- append a line to a log file (creates if missing)
class CFileLog
  {
public:
   static bool Write(const string file,const string line)
     {
      int h=FileOpen(file,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);
      if(h==INVALID_HANDLE) return false;
      FileSeek(h,0,SEEK_END);
      FileWriteString(h,line+"\r\n");
      FileClose(h);
      return true;
     }
  };

#endif // MQL5_OPENAI_CONFIG_MQH
