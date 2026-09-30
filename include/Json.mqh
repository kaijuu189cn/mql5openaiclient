//+------------------------------------------------------------------+
//|                                             include/Json.mqh     |
//|  Self-contained JSON parser & serializer for MQL5 (no DLL, no    |
//|  external libraries). Used for OpenAI request/response handling. |
//|  Tree is stored in a flat node pool; path syntax "a.b[0].c".     |
//+------------------------------------------------------------------+
#ifndef MQL5_OPENAI_JSON_MQH
#define MQL5_OPENAI_JSON_MQH

//--- JSON node kinds
enum JType
  {
   J_NULL=0,
   J_BOOL,
   J_NUMBER,
   J_STRING,
   J_OBJECT,
   J_ARRAY
  };

//--- Tree node stored in a flat array
struct JNode
  {
   int    parent;      // index of parent, -1 = root
   int    first;       // index of first child, -1 = none
   int    next;        // index of next sibling, -1 = none
   int    type;        // JType
   string key;         // object member name (empty for array items / root)
   string val;         // decoded string value or raw number/bool literal
  };

class CJson
  {
private:
   JNode  m_n[];       // node pool
   string m_err;       // last error text
   string m_txt;       // text being parsed
   int    m_pos;       // scan position
   int    m_len;       // text length
   int    m_root;      // root node index

   int    AddNode(const int parent,const string key,const int type);
   int    LastChild(const int node) const;
   bool   SkipWs(void);
   bool   ReadQuotedStr(string &out);
   bool   ParseVal(const int node);
   bool   ParseObj(const int node);
   bool   ParseArr(const int node);
   bool   ParseStr(const int node);
   bool   ParseNum(const int node);
   bool   ParseLit(const int node);
   bool   Resolve(const string path,int &node) const;
   bool   NextSeg(const string path,int &pos,string &seg) const;
   string SerializeNode(const int node) const;

public:
   CJson(void){ m_pos=0; m_len=0; m_root=-1; m_err=""; m_txt=""; }
   void   Clear(void);
   bool   Parse(const string text);
   string Error(void) const                { return m_err; }
   int    Type(void) const;
   int    Count(const string path="") const;
   bool   Has(const string path) const;
   string GetString(const string path,const string def="") const;
   double GetDouble(const string path,const double def=0.0) const;
   long   GetInt(const string path,const long def=0) const;
   bool   GetBool(const string path,const bool def=false) const;
   string GetRaw(const string path,const string def="") const;   // re-serialize that node
   //--- static builders
   static string Escape(const string s);   // escape a string for JSON (no quotes)
   static string Quote(const string s);    // escape + surround with quotes
  };

//+------------------------------------------------------------------+
//|  implementation                                                   |
//+------------------------------------------------------------------+
void CJson::Clear(void)
  {
   ArrayResize(m_n,0);
   m_err="";
   m_txt="";
   m_pos=0;
   m_len=0;
   m_root=-1;
  }

int CJson::AddNode(const int parent,const string key,const int type)
  {
   int idx=ArraySize(m_n);
   ArrayResize(m_n,idx+1);
   m_n[idx].parent=parent;
   m_n[idx].first=-1;
   m_n[idx].next=-1;
   m_n[idx].type=type;
   m_n[idx].key=key;
   m_n[idx].val="";
   if(parent>=0)
     {
      if(m_n[parent].first<0)
         m_n[parent].first=idx;
      else
        {
         int l=LastChild(parent);
         m_n[l].next=idx;
        }
     }
   return idx;
  }

int CJson::LastChild(const int node) const
  {
   int c=m_n[node].first;
   if(c<0) return -1;
   while(m_n[c].next>=0) c=m_n[c].next;
   return c;
  }

bool CJson::SkipWs(void)
  {
   while(m_pos<m_len)
     {
      ushort c=StringGetCharacter(m_txt,m_pos);
      if(c==' ' || c=='\t' || c=='\r' || c=='\n') m_pos++;
      else break;
     }
   return m_pos<m_len;
  }

bool CJson::ReadQuotedStr(string &out)
  {
   if(m_pos>=m_len || StringGetCharacter(m_txt,m_pos)!='"')
     {
      m_err="expected '\"'";
      return false;
     }
   m_pos++;
   out="";
   while(m_pos<m_len)
     {
      ushort c=StringGetCharacter(m_txt,m_pos);
      if(c=='"')
        {
         m_pos++;
         return true;
        }
      if(c=='\\')
        {
         m_pos++;
         if(m_pos>=m_len) break;
         ushort e=StringGetCharacter(m_txt,m_pos);
         m_pos++;
         if(e=='"')       out+=ShortToString((ushort)'"');
         else if(e=='\\') out+=ShortToString((ushort)'\\');
         else if(e=='/')  out+=ShortToString((ushort)'/');
         else if(e=='b')  out+=ShortToString((ushort)8);
         else if(e=='f')  out+=ShortToString((ushort)12);
         else if(e=='n')  out+=ShortToString((ushort)10);
         else if(e=='r')  out+=ShortToString((ushort)13);
         else if(e=='t')  out+=ShortToString((ushort)9);
         else if(e=='u')
           {
            if(m_pos+4>m_len){ m_err="bad \\u escape"; return false; }
            int code=0;
            for(int i=0;i<4;i++)
              {
               ushort h=StringGetCharacter(m_txt,m_pos+i);
               int d=0;
               if(h>='0' && h<='9')       d=h-'0';
               else if(h>='a' && h<='f')  d=h-'a'+10;
               else if(h>='A' && h<='F')  d=h-'A'+10;
               else { m_err="bad \\u escape"; return false; }
               code=code*16+d;
              }
            m_pos+=4;
            out+=ShortToString((ushort)code);
           }
         else
           {
            m_err="bad escape char";
            return false;
           }
        }
      else
        {
         out+=ShortToString(c);
         m_pos++;
        }
     }
   m_err="unterminated string";
   return false;
  }

bool CJson::Parse(const string text)
  {
   Clear();
   m_txt=text;
   m_len=StringLen(text);
   if(m_len==0){ m_err="empty input"; return false; }
   m_root=AddNode(-1,"",J_NULL);
   if(!SkipWs()){ m_err="unexpected end of input"; return false; }
   if(!ParseVal(m_root)) return false;
   SkipWs();
   if(m_pos<m_len){ m_err="trailing data"; return false; }
   return true;
  }

bool CJson::ParseVal(const int node)
  {
   if(!SkipWs()){ m_err="unexpected end of input"; return false; }
   ushort c=StringGetCharacter(m_txt,m_pos);
   if(c=='{') return ParseObj(node);
   if(c=='[') return ParseArr(node);
   if(c=='"') return ParseStr(node);
   if(c=='t' || c=='f' || c=='n') return ParseLit(node);
   if(c=='-' || c=='+' || (c>='0' && c<='9')) return ParseNum(node);
   m_err="unexpected character";
   return false;
  }

bool CJson::ParseObj(const int node)
  {
   m_n[node].type=J_OBJECT;
   m_pos++;   // consume '{'
   if(!SkipWs()){ m_err="unterminated object"; return false; }
   if(m_pos<m_len && StringGetCharacter(m_txt,m_pos)=='}')
     {
      m_pos++;
      return true;
     }
   while(true)
     {
      if(!SkipWs()){ m_err="unterminated object"; return false; }
      string key="";
      ushort c=StringGetCharacter(m_txt,m_pos);
      if(c=='"')
        {
         if(!ReadQuotedStr(key)) return false;
        }
      else
        {
         // lenient: unquoted key
         while(m_pos<m_len)
           {
            ushort k=StringGetCharacter(m_txt,m_pos);
            if(k==':' || k==' ' || k=='\t' || k=='\r' || k=='\n') break;
            key+=ShortToString(k);
            m_pos++;
           }
         StringTrimRight(key);
         if(key==""){ m_err="empty key in object"; return false; }
        }
      if(!SkipWs()){ m_err="expected ':' after key"; return false; }
      if(StringGetCharacter(m_txt,m_pos)!=':'){ m_err="expected ':' after key"; return false; }
      m_pos++;
      int child=AddNode(node,key,J_NULL);
      if(!ParseVal(child)) return false;
      if(!SkipWs()){ m_err="unterminated object"; return false; }
      c=StringGetCharacter(m_txt,m_pos);
      if(c==','){ m_pos++; continue; }
      if(c=='}'){ m_pos++; return true; }
      m_err="expected ',' or '}' in object";
      return false;
     }
   return true;
  }

bool CJson::ParseArr(const int node)
  {
   m_n[node].type=J_ARRAY;
   m_pos++;   // consume '['
   if(!SkipWs()){ m_err="unterminated array"; return false; }
   if(m_pos<m_len && StringGetCharacter(m_txt,m_pos)==']')
     {
      m_pos++;
      return true;
     }
   while(true)
     {
      if(!SkipWs()){ m_err="unterminated array"; return false; }
      int child=AddNode(node,"",J_NULL);
      if(!ParseVal(child)) return false;
      if(!SkipWs()){ m_err="unterminated array"; return false; }
      ushort c=StringGetCharacter(m_txt,m_pos);
      if(c==','){ m_pos++; continue; }
      if(c==']'){ m_pos++; return true; }
      m_err="expected ',' or ']' in array";
      return false;
     }
   return true;
  }

bool CJson::ParseStr(const int node)
  {
   string s;
   if(!ReadQuotedStr(s)) return false;
   m_n[node].type=J_STRING;
   m_n[node].val=s;
   return true;
  }

bool CJson::ParseNum(const int node)
  {
   int start=m_pos;
   while(m_pos<m_len)
     {
      ushort c=StringGetCharacter(m_txt,m_pos);
      if((c>='0' && c<='9') || c=='-' || c=='+' || c=='.' || c=='e' || c=='E')
         m_pos++;
      else break;
     }
   if(m_pos==start){ m_err="invalid number"; return false; }
   m_n[node].type=J_NUMBER;
   m_n[node].val=StringSubstr(m_txt,start,m_pos-start);
   return true;
  }

bool CJson::ParseLit(const int node)
  {
   if(StringSubstr(m_txt,m_pos,4)=="true")
     {
      m_pos+=4;
      m_n[node].type=J_BOOL;
      m_n[node].val="true";
      return true;
     }
   if(StringSubstr(m_txt,m_pos,5)=="false")
     {
      m_pos+=5;
      m_n[node].type=J_BOOL;
      m_n[node].val="false";
      return true;
     }
   if(StringSubstr(m_txt,m_pos,4)=="null")
     {
      m_pos+=4;
      m_n[node].type=J_NULL;
      m_n[node].val="null";
      return true;
     }
   m_err="invalid literal";
   return false;
  }

bool CJson::NextSeg(const string path,int &pos,string &seg) const
  {
   int n=StringLen(path);
   if(pos>=n) return false;
   int start=pos;
   while(pos<n && StringGetCharacter(path,pos)!='.') pos++;
   seg=StringSubstr(path,start,pos-start);
   if(pos<n) pos++;   // skip '.'
   return true;
  }

bool CJson::Resolve(const string path,int &node) const
  {
   if(m_root<0) return false;
   node=m_root;
   if(path=="" || path==".") return true;
   int pos=0;
   string seg;
   while(NextSeg(path,pos,seg))
     {
      if(seg=="") continue;
      // split segment name and optional [index]
      string name=seg;
      int idx=-1;
      int bp=StringFind(seg,"[");
      if(bp>=0)
        {
         int ep=StringFind(seg,"]");
         if(ep>bp)
           {
            name=StringSubstr(seg,0,bp);
            string istr=StringSubstr(seg,bp+1,ep-bp-1);
            StringTrimLeft(istr);
            StringTrimRight(istr);
            if(istr!="") idx=(int)StringToInteger(istr);
           }
        }
      int t=m_n[node].type;
      int child=m_n[node].first;
      if(t==J_OBJECT)
        {
         bool found=false;
         while(child>=0)
           {
            if(m_n[child].key==name){ found=true; break; }
            child=m_n[child].next;
           }
         if(!found) return false;
         node=child;
        }
      else if(t==J_ARRAY)
        {
         if(idx<0) return false;   // array paths must use [n]
         int c=0;
         while(child>=0)
           {
            if(c==idx){ node=child; break; }
            child=m_n[child].next;
            c++;
           }
         if(child<0) return false;
        }
      else return false;
     }
   return true;
  }

int CJson::Type(void) const
  {
   if(m_root<0) return J_NULL;
   return m_n[m_root].type;
  }

int CJson::Count(const string path="") const
  {
   int node;
   if(!Resolve(path,node)) return 0;
   int c=m_n[node].first;
   int k=0;
   while(c>=0){ k++; c=m_n[c].next; }
   return k;
  }

bool CJson::Has(const string path) const
  {
   int node;
   return Resolve(path,node);
  }

string CJson::GetString(const string path,const string def="") const
  {
   int node;
   if(!Resolve(path,node)) return def;
   if(m_n[node].type==J_STRING) return m_n[node].val;
   if(m_n[node].type==J_NUMBER || m_n[node].type==J_BOOL) return m_n[node].val;
   return def;
  }

double CJson::GetDouble(const string path,const double def=0.0) const
  {
   int node;
   if(!Resolve(path,node)) return def;
   if(m_n[node].type==J_NUMBER || m_n[node].type==J_STRING)
      return StringToDouble(m_n[node].val);
   return def;
  }

long CJson::GetInt(const string path,const long def=0) const
  {
   int node;
   if(!Resolve(path,node)) return def;
   if(m_n[node].type==J_NUMBER || m_n[node].type==J_STRING)
      return (long)StringToDouble(m_n[node].val);
   return def;
  }

bool CJson::GetBool(const string path,const bool def=false) const
  {
   int node;
   if(!Resolve(path,node)) return def;
   if(m_n[node].type==J_BOOL) return (m_n[node].val=="true");
   if(m_n[node].type==J_STRING)
     {
      string v=m_n[node].val;
      StringToUpper(v);
      return (v=="true" || v=="1" || v=="yes");
     }
   return def;
  }

string CJson::GetRaw(const string path,const string def="") const
  {
   int node;
   if(!Resolve(path,node)) return def;
   return SerializeNode(node);
  }

string CJson::SerializeNode(const int node) const
  {
   if(node<0) return "null";
   int t=m_n[node].type;
   if(t==J_NULL) return "null";
   if(t==J_BOOL || t==J_NUMBER) return m_n[node].val;
   if(t==J_STRING) return Quote(m_n[node].val);
   if(t==J_ARRAY)
     {
      string s="[";
      int c=m_n[node].first;
      while(c>=0)
        {
         s+=SerializeNode(c);
         c=m_n[c].next;
         if(c>=0) s+=",";
        }
      s+="]";
      return s;
     }
   // object
   string s="{";
   int c=m_n[node].first;
   while(c>=0)
     {
      s+=Quote(m_n[c].key)+":"+SerializeNode(c);
      c=m_n[c].next;
      if(c>=0) s+=",";
     }
   s+="}";
   return s;
  }

string CJson::Escape(const string s)
  {
   string r="";
   int n=StringLen(s);
   for(int i=0;i<n;i++)
     {
      ushort c=StringGetCharacter(s,i);
      if(c=='"')       r+="\\\"";
      else if(c=='\\') r+="\\\\";
      else if(c=='\n') r+="\\n";
      else if(c=='\r') r+="\\r";
      else if(c=='\t') r+="\\t";
      else if(c=='\b') r+="\\b";
      else if(c=='\f') r+="\\f";
      else if(c<0x20)  r+=StringFormat("\\u%04x",(int)c);
      else             r+=ShortToString(c);
     }
   return r;
  }

string CJson::Quote(const string s)
  {
   return "\""+Escape(s)+"\"";
  }

#endif // MQL5_OPENAI_JSON_MQH
