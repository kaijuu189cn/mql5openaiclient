//+------------------------------------------------------------------+
//|                                            include/HttpClient.mqh |
//|  Minimal HTTP(S) client on top of MQL5 WebRequest (no DLL).      |
//|  Handles the char[] / UTF-8 pitfalls of WebRequest for JSON      |
//|  request/response bodies. Requires the URL to be whitelisted in  |
//|  MT5: Tools -> Options -> Expert Advisors -> "Allow WebRequest   |
//|  for listed URL" (add e.g. https://api.openai.com).              |
//+------------------------------------------------------------------+
#ifndef MQL5_OPENAI_HTTPCLIENT_MQH
#define MQL5_OPENAI_HTTPCLIENT_MQH

//--- well-known WebRequest error codes
#define HTTP_ERR_OK         0
#define HTTP_ERR_TIMEOUT    4010   // timeout
#define HTTP_ERR_WRONG_IP   4012   // wrong IP
#define HTTP_ERR_DNS        4013   // DNS failure
#define HTTP_ERR_NOT_LISTED 4014   // URL not allowed
#define HTTP_ERR_CONNECT    4016   // cannot connect
#define HTTP_ERR_SEND       4018
#define HTTP_ERR_RECV       4019

class CHttpClient
  {
private:
   string   m_lastError;
   string   m_ua;                       // user agent header value

public:
   CHttpClient(void){ m_lastError=""; m_ua="MQL5-OpenAI/1.0"; }

   string   LastError(void) const { return m_lastError; }

   //--- UTF-8 encode a string into a char array (WebRequest body type)
   // NOTE: StringToCharArray with CP_UTF8 (65001) prepends a UTF-8 BOM
   // (EF BB BF); strip it so the JSON body starts with '{'.
   static int Utf8Encode(const string text,char &out[])
     {
      uchar u[];
      int n=StringToCharArray(text,u,0,WHOLE_ARRAY,65001);   // CP_UTF8
      int len=(n>0)?n-1:0;                                    // drop terminator
      int skip=0;
      if(len>=3 && u[0]==0xEF && u[1]==0xBB && u[2]==0xBF)
         skip=3;                                              // strip UTF-8 BOM
      len-=skip;
      if(len<0) len=0;
      ArrayResize(out,len);
      for(int i=0;i<len;i++) out[i]=(char)u[i+skip];
      return len;
     }

   //--- decode a WebRequest char[] result back to a string (UTF-8)
   static string Utf8Decode(char &in[],const int len)
     {
      if(len<=0) return "";
      uchar u[];
      ArrayResize(u,len);
      for(int i=0;i<len;i++) u[i]=(uchar)in[i];
      return CharArrayToString(u,0,len,65001);
     }

   //--- POST JSON: returns HTTP status code (200..), or -1 on transport error
   int PostJson(const string url,const string headers,const string body,
                const int timeoutMs,string &outBody,string &outRespHeaders)
     {
      m_lastError="";
      string h=headers;
      if(StringFind(h,"Content-Type")<0)
         h+=(StringLen(h)>0?"\r\n":"")+"Content-Type: application/json";
      if(StringFind(h,"User-Agent")<0)
         h+=(StringLen(h)>0?"\r\n":"")+"User-Agent: "+m_ua;

      char data[];
      Utf8Encode(body,data);

      char result[];
      string resultHeaders="";
      ResetLastError();
      int code=WebRequest("POST",url,h,timeoutMs,data,result,resultHeaders);

      if(code<0)
        {
         int err=GetLastError();
         string reason=HttpErrorText(err);
         m_lastError=StringFormat("WebRequest failed, error=%d (%s), url=%s",
                                  err,reason,url);
         return -1;
        }

      outRespHeaders=resultHeaders;
      int n=ArraySize(result);
      // drop a trailing NUL if present
      if(n>0 && result[n-1]==0) n--;
      outBody=Utf8Decode(result,n);
      return code;
     }

   //--- GET: returns HTTP status code, or -1 on transport error
   int Get(const string url,const string headers,const int timeoutMs,
           string &outBody,string &outRespHeaders)
     {
      m_lastError="";
      string h=headers;
      if(StringFind(h,"User-Agent")<0)
         h+=(StringLen(h)>0?"\r\n":"")+"User-Agent: "+m_ua;

      char result[];
      char empty[];
      ArrayResize(empty,0);
      string resultHeaders="";
      ResetLastError();
      int code=WebRequest("GET",url,h,timeoutMs,empty,result,resultHeaders);
      if(code<0)
        {
         int err=GetLastError();
         m_lastError=StringFormat("WebRequest failed, error=%d (%s), url=%s",
                                  err,HttpErrorText(err),url);
         return -1;
        }
      outRespHeaders=resultHeaders;
      int n=ArraySize(result);
      if(n>0 && result[n-1]==0) n--;
      outBody=Utf8Decode(result,n);
      return code;
     }

   //--- human readable text for a WebRequest error code
   static string HttpErrorText(const int err)
     {
      switch(err)
        {
         case HTTP_ERR_OK:         return "OK";
         case HTTP_ERR_TIMEOUT:    return "timeout";
         case HTTP_ERR_WRONG_IP:   return "wrong IP address";
         case HTTP_ERR_DNS:        return "DNS resolution failed";
         case HTTP_ERR_NOT_LISTED: return "URL is not in the allowed list";
         case HTTP_ERR_CONNECT:    return "cannot connect to the server";
         case HTTP_ERR_SEND:       return "error while sending data";
         case HTTP_ERR_RECV:       return "error while receiving data";
         default:                  return StringFormat("unknown (%d)",err);
        }
     }
  };

#endif // MQL5_OPENAI_HTTPCLIENT_MQH
