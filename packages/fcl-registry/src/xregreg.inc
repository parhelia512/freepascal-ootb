{
    This file is part of the Free Pascal run time library.
    Copyright (c) 1999-2022 by Michael van Canneyt and other members of the
    Free Pascal development team

    XML Registry aux support

    See the file COPYING.FPC, included in this distribution,
    for details about the copyright.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

 **********************************************************************}


{ ---------------------------------------------------------------------
    System dependent Registry implementation - using XML file.
  ---------------------------------------------------------------------}

uses typinfo, xmlreg;

Const
  XFileName = 'reg.xml';

Resourcestring
  SErrTypeNotSupported = 'Registry data type not supported on this platform: %s';

Function RegDataTypeToXmlDataType(RegData : TRegDataType) : TDataType;

begin
  Case RegData of
    rdUnknown               : Result := dtUnknown;
    rdString,rdExpandString : Result := dtString;
    rdInteger               : Result := dtDword;
    rdBinary                : Result := dtBinary;
    rdMultiString           : Result := dtStrings;
  else
    Raise ERegistryException.CreateFmt(SErrTypeNotSupported,[GetEnumName(TypeInfo(TRegDataType),Ord(RegData))]);
  end;
end;

Function DataTypeToRegDataType(DataType : TDataType) : TRegDataType;

begin
  Case DataType of
    dtUnknown: Result:=rdUnknown;
    dtDword  : Result:=rdInteger;
    dtString : Result:=rdString;
    dtBinary : Result:=rdBinary;
    dtStrings : Result:=rdMultiString;
  end;
end;

Function RootKeyToRootKeyStr(Value: HKEY): UnicodeString;

begin
  Case Value of
    HKEY_CLASSES_ROOT     : Result := 'HKEY_CLASSES_ROOT';
    HKEY_CURRENT_USER     : Result := 'HKEY_CURRENT_USER';
    HKEY_LOCAL_MACHINE    : Result := 'HKEY_LOCAL_MACHINE';
    HKEY_USERS            : Result := 'HKEY_USERS';
    HKEY_PERFORMANCE_DATA : Result := 'HKEY_PERFORMANCE_DATA';
    HKEY_CURRENT_CONFIG   : Result := 'HKEY_CURRENT_CONFIG';
    HKEY_DYN_DATA         : Result := 'HKEY_DYN_DATA';
  else
    Result:=Format('Key%d',[Value]);
  end;
end;

type

  { TXMLRegistryInstance }

  TXMLRegistryInstance = class(TXMLRegistry)
  private
    FRefCount: integer;
    Class Var XMLRegistryCache: Tlist;
    Class procedure FreeXMLRegistryCache;
  public
    constructor Create(AFileName : String);
    Class Function GetXMLRegistry(aFileName: string): TXMLRegistry;
    Class Procedure FreeXMLRegistry(XMLRegistry: TXMLRegistry);
    procedure IncRefCount;
    procedure DecRefCount;
    property RefCount: integer read FRefCount;
  end;

Class function TXMLRegistryInstance.GetXMLRegistry(aFileName: string): TXMLRegistry;
var i: integer;
begin
  if not assigned(XMLRegistryCache) then
    XMLRegistryCache := TList.Create;

  for i := 0 to XMLRegistryCache.Count - 1 do
    if TXMLRegistryInstance(XMLRegistryCache[i]).FileName = aFileName then
    begin
      TXMLRegistryInstance(XMLRegistryCache[i]).IncRefCount;
      Result :=  TXMLRegistry(XMLRegistryCache[i]);
      Exit;
    end;

  Result := TXMLRegistryInstance.Create(aFileName);
  XMLRegistryCache.Add(Result);
end;

Class procedure TXMLRegistryInstance.FreeXMLRegistry(XMLRegistry: TXMLRegistry);
begin
  TXMLRegistryInstance(XMLRegistry).DecRefCount;
  if TXMLRegistryInstance(XMLRegistry).RefCount = 0 then
  begin
    XMLRegistryCache.Remove(XMLRegistry);
    XMLRegistry.Free;
  end;
end;

class procedure TXMLRegistryInstance.FreeXMLRegistryCache;

var i: integer;
begin
  if not Assigned(XMLRegistryCache) then
    exit;
  for i := 0 to XMLRegistryCache.Count - 1 do
    TXMLRegistryInstance(XMLRegistryCache[i]).Free;
  FreeAndNil(XMLRegistryCache);
end;


{ TXMLRegistryInstance }

constructor TXMLRegistryInstance.Create(AFileName: String);
begin
  inherited;
  FRefCount := 1;
end;

procedure TXMLRegistryInstance.IncRefCount;
begin
  Inc(FRefCount);
end;

procedure TXMLRegistryInstance.DecRefCount;
begin
  Dec(FRefCount);
end;

procedure useKeyFromTRegistryInstance(reg: TRegistry);
var XmlRegistry: TXMLRegistry;
    RootKeyStr: UnicodeString;
begin
  XmlRegistry:=TXMLRegistry(reg.FSysData);
  RootKeyStr:=RootKeyToRootKeyStr(reg.RootKey);

  // '/' at the end when comparing
  if (reg.CurrentKey=0) and (UnicodeCompareText(XmlRegistry.RootKey, RootKeyStr + '/')<>0) then
    XmlRegistry.SetRootKey(RootKeyStr)
  else
    begin
    if UnicodeCompareText(XmlRegistry.CurrentKey, RootKeyStr+'/'+reg.CurrentPath + '/')<>0 then
      begin
      XmlRegistry.SetRootKey(RootKeyStr);
      XmlRegistry.SetKey(reg.CurrentPath, false);
      end;
    end;
end;

procedure TRegistry.SysRegCreate;
var s : string;
begin
  FStringSizeIncludesNull:=False;
  s:=includetrailingpathdelimiter(GetAppConfigDir(GlobalXMLFile));
  {$ifdef XMLRegfile_in_CurDir}
  s:='.' + PathDelim;
  {$endif}
  ForceDirectories(s);
  FSysData:=TXMLRegistryInstance.GetXMLRegistry(s+XFileName);
  TXmlRegistry(FSysData).AutoFlush:=False;
end;

procedure TRegistry.SysRegFree;

begin
  if Assigned(FSysData) then
    TXMLRegistry(FSysData).Flush;
  TXMLRegistryInstance.FreeXMLRegistry(TXMLRegistry(FSysData));
end;

function TRegistry.SysCreateKey(Key: UnicodeString): Boolean;

begin
  useKeyFromTRegistryInstance(self);
  Result:=TXmlRegistry(FSysData).CreateKey(Key);
end;

function TRegistry.DeleteKey(const Key: UnicodeString): Boolean;

begin
  useKeyFromTRegistryInstance(self);
  Result:=TXMLRegistry(FSysData).DeleteKey(Key);
end;

function TRegistry.DeleteValue(const Name: UnicodeString): Boolean;
begin
  useKeyFromTRegistryInstance(self);
  Result:=TXmlRegistry(FSysData).DeleteValue(Name);
end;

function TRegistry.SysGetData(const Name: UnicodeString; Buffer: Pointer;
          BufSize: Integer; Out RegData: TRegDataType): Integer;

Var
  DataType : TDataType;
begin
  useKeyFromTRegistryInstance(self);
  Result:=BufSize;
  If TXmlregistry(FSysData).GetValueDataUnicode(Name,DataType,Buffer^,Result) then
    RegData:=DataTypeToRegDataType(DataType)
  else
    Result:=-1;
end;

function TRegistry.GetDataInfo(const ValueName: UnicodeString; out Value: TRegDataInfo): Boolean;

Var
  Info : TDataInfo;

begin
  useKeyFromTRegistryInstance(self);
  Result := TXmlRegistry(FSysData).GetValueInfo(ValueName,Info,True);
  If Not Result then
    With Value do
      begin
      RegData:=rdunknown;
      DataSize:=0;
      end
  else
    With Value do
      begin
      RegData:=DataTypeToRegDataType(Info.DataType);
      DataSize:=Info.DataSize;
      end;
end;

function TRegistry.GetKey(Key: UnicodeString): HKEY;
begin
  Result := 0;
end;

function TRegistry.GetKeyInfo(Out Value: TRegKeyInfo): Boolean;

Var
  Info : TKeyInfo;

begin
  useKeyFromTRegistryInstance(self);
  Result:=TXmlRegistry(FSysData).GetKeyInfo(info);
  If Result then
    With Value,Info do
      begin
      NumSubKeys:=SubKeys;
      MaxSubKeyLen:=SubKeyLen;
      NumValues:= Values;
      MaxValueLen:=ValueLen;
      MaxDataLen:=DataLen;
      FileTime:=FTime;
      end;
end;

function TRegistry.KeyExists(const Key: UnicodeString): Boolean;
begin
  useKeyFromTRegistryInstance(self);
  Result:=TXmlRegistry(FSysData).KeyExists(Key);
end;

function TRegistry.LoadKey(const Key, FileName: UnicodeString): Boolean;
begin
  Result := False;
end;

function TRegistry.OpenKey(const Key: UnicodeString; CanCreate: Boolean): Boolean;

var
  S: UnicodeString;
  P: SizeInt;
begin
  useKeyFromTRegistryInstance(self);
  Result:=TXmlRegistry(FSysData).SetKey(Key,CanCreate);
  If Result then begin
    fCurrentKey:=1;
    S:=TXmlRegistry(FSysData).CurrentKey;
    if (S>'') then begin
      //S starts with RootKey+'/'
      P:=Pos('/',S);
      if (P>0) then
        System.Delete(S,1,P);
    end;
    ChangeKey(fCurrentKey, S);
  end;
end;

function TRegistry.OpenKeyReadOnly(const Key: UnicodeString): Boolean;

begin
  Result:=OpenKey(Key,False);
end;

function TRegistry.RegistryConnect(const UNCName: UnicodeString): Boolean;
begin
  Result := True;
end;

function TRegistry.ReplaceKey(const Key, FileName, BackUpFileName: UnicodeString): Boolean;
begin
  Result := False;
end;

function TRegistry.RestoreKey(const Key, FileName: UnicodeString): Boolean;
begin
  Result := False;
end;

function TRegistry.SaveKey(const Key, FileName: UnicodeString): Boolean;
begin
  Result := False;
end;

function TRegistry.UnLoadKey(const Key: UnicodeString): Boolean;
begin
  Result := False;
end;

function TRegistry.ValueExists(const Name: UnicodeString): Boolean;
begin
  useKeyFromTRegistryInstance(self);
  Result := TXmlRegistry(FSysData).ValueExists(Name);
end;

procedure TRegistry.ChangeKey(Value: HKey; const Path: UnicodeString);
begin
  FCurrentPath:=FixPath(Path);
end;

function TRegistry.GetKeyNames: TUnicodeStringArray;
begin
  useKeyFromTRegistryInstance(self);
  Result:=TXmlRegistry(FSysData).EnumSubKeys;
end;

function TRegistry.GetValueNames: TUnicodeStringArray;
begin
  useKeyFromTRegistryInstance(self);
  Result := TXmlRegistry(FSysData).EnumValues;
end;


function TRegistry.SysPutData(const Name: UnicodeString; Buffer: Pointer;
  BufSize: Integer; RegData: TRegDataType): Boolean;

Var
  DataType : TDataType;

begin
  useKeyFromTRegistryInstance(self);
  //writeln('TRegistry.SysPutData: Name=',Name,', RegData=',RegData,', BufSize=',BufSize);
  DataType:=RegDataTypeToXmlDataType(RegData);

  Result:=TXMLRegistry(FSysData).SetValueDataUnicode(Name,DataType,Buffer^,BufSize);
end;

procedure TRegistry.RenameValue(const OldName, NewName: UnicodeString);
begin
  useKeyFromTRegistryInstance(self);
  TXMLRegistry(FSysData).RenameValue(OldName,NewName);
end;


procedure TRegistry.SetCurrentKey(Value: HKEY);
begin
  fCurrentKey := Value;
end;

procedure TRegistry.SetRootKey(Value: HKEY);

Var
  S: UnicodeString;

begin
  S:=RootKeyToRootKeyStr(Value);
  TXmlRegistry(FSysData).SetRootKey(S);
  fRootKey := Value;
  fCurrentKey:=0;
  FCurrentPath:='';
end;

function TRegistry.GetLastErrorMsg: string;
begin
  Result:='';
end;

procedure TRegistry.CloseKey;

begin
  // CloseKey is called from destructor, which includes cases of failed construction.
  // FSysData may be unassigned at this point.
  if Assigned(FSysData) then
  begin
    TXMLRegistry(FSysData).Flush;
    TXMLRegistry(FSysData).SetRootKey(TXMLRegistry(FSysData).RootKey);
    fCurrentKey:=0;
    FCurrentPath:='';
  end;
end;

procedure TRegistry.CloseKey(key:HKEY);

begin
  if Assigned(FSysData) then
  begin
    TXMLRegistry(FSysData).Flush;
    TXMLRegistry(FSysData).SetRootKey(TXMLRegistry(FSysData).RootKey);
    fCurrentKey:=0;
    FCurrentPath:='';
  end;
end;


