library DrawMarker_CaptureProbe;

// Diagnostic filter used only in the isolated AviUtl2 installation.
uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  System.SyncObjs, Vcl.Forms,
  AviUtl2FilterTypes in '..\Source\Lib\AviUtl2FilterTypes.pas',
  PluginFilterTable in '..\Source\Lib\FilterTable\PluginFilterTable.pas',
  DrawMarker_Capture in '..\Source\Plugin\Filter\DrawMarker_Capture.pas';

const
  ProbeName = '描画入力検証';
  TestValue = '検証値';
  TestData = '検証データ';
  WM_SCENE = WM_APP + 71;
  WM_RECEIVED = WM_APP + 72;

type
  TProbeDispatcher = class
    procedure WindowProc(var Msg: TMessage);
  end;

var
  Capture: TInputCapture;
  Host: PEDIT_HANDLE;
  Buttons: array[0..6] of TFILTER_ITEM_BUTTON;
  Data: TFILTER_ITEM_DATA;
  Hide: TFILTER_ITEM_HIDE_RULE;
  Track: TFILTER_ITEM_TRACK;
  Items: array[0..10] of Pointer;
  EmptyItems: Pointer;
  Probe, Prefix: TFILTER_PLUGIN_TABLE;
  LogLock: TCriticalSection;
  Sink: HWND;
  Dispatcher: TProbeDispatcher;
  Serial, LastMatch: Integer;
  Current: TMarkerTarget;
  LogFile: string;
  Reply: TMarkerCapture;

procedure Log(const Line: string);
var Text: UTF8String; Stream: TFileStream; Stamp: Int64;
begin
  QueryPerformanceCounter(Stamp);
  Text := UTF8String(Format('%s qpc=%d thread=%d %s'#13#10,
    [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), Stamp, GetCurrentThreadId, Line]));
  LogLock.Acquire;
  try
    if FileExists(LogFile) then Stream := TFileStream.Create(LogFile, fmOpenReadWrite or fmShareDenyNone)
    else Stream := TFileStream.Create(LogFile, fmCreate or fmShareDenyNone);
    try
      Stream.Seek(0, soEnd);
      Stream.WriteBuffer(Text[1], Length(Text));
    finally
      Stream.Free;
    end;
  finally
    LogLock.Release;
  end;
end;

procedure SceneReady(Param: Pointer; Frame: Integer; Buffer: Pointer;
  Width, Height, Pitch: Integer); cdecl;
var Pixel: TPIXEL_RGBA;
begin
  try
    Pixel := Default(TPIXEL_RGBA);
    if Buffer <> nil then Pixel := PPIXEL_RGBA(Buffer)^;
    Log(Format('scene completion #%d frame=%d size=%dx%d pitch=%d rgba=%d,%d,%d,%d',
      [NativeUInt(Param), Frame, Width, Height, Pitch, Pixel.R, Pixel.G, Pixel.B, Pixel.A]));
  except
  end;
end;

procedure TProbeDispatcher.WindowProc(var Msg: TMessage);
var Accepted: Boolean; P: TPIXEL_RGBA; Frame: TMarkerCapture;
begin
  try
    case Msg.Msg of
      WM_SCENE:
        if NativeUInt(Msg.WParam) = NativeUInt(Serial) then
        begin
          Log(Format('API begin #%d rendering_scene_video', [Serial]));
          Accepted := Host^.RenderingSceneVideo(Current.Frame, Pointer(NativeUInt(Serial)), SceneReady);
          Log(Format('API return #%d rendering_scene_video=%s', [Serial, BoolToStr(Accepted, True)]));
        end;
      WM_RECEIVED:
        begin
          LogLock.Acquire;
          try
            Frame := Reply;
            Reply := Default(TMarkerCapture);
          finally
            LogLock.Release;
          end;
          if Length(Frame.Pixels) > 0 then
          begin
            P := Frame.Pixels[0];
            Log(Format('UI received #%d %dx%d rgba=%d,%d,%d,%d',
              [Frame.Token, Frame.Width, Frame.Height, P.R, P.G, P.B, P.A]));
          end;
        end;
      WM_TIMER:
        begin
          KillTimer(Sink, 1);
          Capture.Cancel(Serial);
          Log(Format('observation expired #%d', [Serial]));
          TInterlocked.Exchange(LastMatch, 0);
        end;
    else
      Msg.Result := DefWindowProc(Sink, Msg.Msg, Msg.WParam, Msg.LParam);
    end;
  except
  end;
end;

procedure Press(Edit: PEDIT_SECTION; Obj: OBJECT_HANDLE; Effect, Item: PWideChar); cdecl;
var
  EffectHandle: EFFECT_HANDLE;
  DataValue: Integer;
  Value, Next: UTF8String;
  Accepted: Boolean;
  Mode: Char;
  Title: array[0..511] of Char;
begin
  try
    if not ReadTarget(Edit, Obj, Effect, Current, EffectHandle) then Exit;
    Mode := Item[0];
    Value := UTF8String(Edit^.GetEffectItemValue(EffectHandle, TestValue));
    DataValue := 0;
    Edit^.GetEffectDataValue(EffectHandle, TestData, @DataValue, SizeOf(DataValue));
    GetWindowText(HWND(Host^.GetHostAppWindow()), Title, Length(Title));
    Log(Format('click %s scene=%d cursorLayer=%d frame=%d objectLayer=%d object=%d effect=%d state=%d value=%s data=%d title=%s',
      [string(Mode), Current.Scene, Current.CursorLayer, Current.Frame, Current.ObjectLayer,
       Current.ObjectID, Current.EffectID, Host^.GetEditState(), string(Value), DataValue, string(Title)]));
    if Mode = 'F' then Exit;
    Inc(Serial);
    Capture.Arm(Current, Serial);
    TInterlocked.Exchange(LastMatch, Serial);
    Log(Format('armed #%d mode=%s', [Serial, string(Mode)]));
    KillTimer(Sink, 1);
    SetTimer(Sink, 1, 2200, nil);
    Accepted := True;
    if Mode <> 'A' then Log(Format('API begin #%d %s', [Serial, string(Item)]));
    case Mode of
      'B': Edit^.SetCursorLayerFrame(Current.CursorLayer, Current.Frame);
      'C': Accepted := Edit^.SetEffectItemValue(EffectHandle, TestValue, PAnsiChar(Value));
      'D':
        begin
          Inc(DataValue);
          Accepted := Edit^.SetEffectDataValue(EffectHandle, TestData, @DataValue, SizeOf(DataValue));
        end;
      'E': Accepted := PostMessage(Sink, WM_SCENE, Serial, 0);
      'G':
        begin
          if Value = '0' then Next := '1' else Next := '0';
          Accepted := Edit^.SetEffectItemValue(EffectHandle, TestValue, PAnsiChar(Next));
        end;
    end;
    Log(Format('button return #%d accepted=%s', [Serial, BoolToStr(Accepted, True)]));
  except
    on E: Exception do Log('button exception: ' + E.Message);
  end;
end;

function Solid(Video: PFILTER_PROC_VIDEO; Color: Cardinal): Byte;
var Pixels: TArray<Cardinal>; W, H, I: Integer;
begin
  W := Video^.Object_^.Width;
  H := Video^.Object_^.Height;
  if (W <= 0) or (H <= 0) or (Int64(W) * H > 2000000) then Exit(1);
  SetLength(Pixels, W * H);
  for I := 0 to High(Pixels) do Pixels[I] := Color;
  Video^.SetImageData(PPIXEL_RGBA(@Pixels[0]), W, H);
  Result := 1;
end;

function PrefixVideo(Video: PFILTER_PROC_VIDEO): Byte; cdecl;
begin
  Result := 1;
  try
    Result := Solid(Video, $FF20C010);
  except
  end;
end;

function ProbeVideo(Video: PFILTER_PROC_VIDEO): Byte; cdecl;
var
  Token: NativeUInt;
  Frame: TMarkerCapture;
  Match: Integer;
  I, Good: Integer;
  P: TPIXEL_RGBA;
begin
  Result := 1;
  try
    Token := Capture.Claim(Video);
    Match := TInterlocked.CompareExchange(LastMatch, 0, 0);
    if Match <> 0 then
      Log(Format('video #%d claimed=%d scene=%d originScene=%d sceneFlag=%d frame=%d local=%d layer=%d effect=%d',
        [Match, Token, Video^.Scene^.ID, Video^.Scene^.OriginID, Video^.Scene^.Flag,
         Video^.Object_^.OriginFrame, Video^.Object_^.Frame, Video^.Object_^.Layer,
         Video^.Object_^.EffectID]));
    if Token <> 0 then
    begin
      if CopyFilterInput(Video, Token, Frame) then
      begin
        Good := 0;
        for I := 0 to High(Frame.Pixels) do
        begin
          P := Frame.Pixels[I];
          if (P.R = 16) and (P.G = 192) and (P.B = 32) and (P.A = 255) then Inc(Good);
        end;
        Log(Format('copy completed #%d correct=%d total=%d', [Token, Good, Length(Frame.Pixels)]));
        LogLock.Acquire;
        try
          Reply := Frame;
        finally
          LogLock.Release;
        end;
        PostMessage(Sink, WM_RECEIVED, 0, 0);
      end
      else Log(Format('copy failed #%d', [Token]));
    end;
    Result := Solid(Video, $FF1818DC);
  except
    on E: Exception do Log('video exception: ' + E.Message);
  end;
end;

function RequiredVersion: Cardinal; cdecl;
begin
  Result := 2011800;
end;

function InitializePlugin(Version: Cardinal): Byte; cdecl;
begin
  Result := 0;
  try
    LogFile := ExtractFilePath(ParamStr(0)) + 'capture-probe.log';
    LogLock := TCriticalSection.Create;
    Capture := TInputCapture.Create;
    Dispatcher := TProbeDispatcher.Create;
    Sink := AllocateHWnd(Dispatcher.WindowProc);
    Log(Format('initialized host version=%d SDK=2026-11-14', [Version]));
    Result := 1;
  except
  end;
end;

procedure RegisterPlugin(Table: PHOST_APP_TABLE); cdecl;
const Labels: array[0..6] of PWideChar = (
  'A　要求登録のみ', 'B　現在位置を再設定', 'C　同じ設定値', 'G　異なる設定値（C）',
  'D　非表示データ', 'E　シーン描画', 'F　状態を記録');
var I: Integer;
begin
  try
    Log('register: set information');
    Table^.SetPluginInformation('SYNC_DrawMarker 入力取得実験');
    Log('register: create handle');
    Host := Table^.CreateEditHandle();
    for I := 0 to High(Buttons) do
    begin
      Buttons[I].ItemType := 'button';
      Buttons[I].Name := Labels[I];
      Buttons[I].Callback2 := Press;
      Items[I] := @Buttons[I];
    end;
    Track.ItemType := 'track';
    Track.Name := TestValue;
    Track.S := 0; Track.E := 1; Track.Step := 1;
    Items[7] := @Track;
    Data.ItemType := 'data';
    Data.Name := TestData;
    Items[8] := @Data;
    Hide.ItemType := 'hiderule';
    Hide.Name := TestData;
    Items[9] := @Hide;
    Probe.Flag := FILTER_FLAG_VIDEO or FILTER_FLAG_FILTER;
    Probe.Name := ProbeName;
    Probe.Label_ := 'SYNC';
    Probe.Information := 'SYNC_DrawMarker filter input probe';
    Probe.Items := @Items[0];
    Probe.Func_Proc_Video := ProbeVideo;
    Prefix.Flag := FILTER_FLAG_VIDEO;
    Prefix.Name := '検証用前段色';
    Prefix.Label_ := 'SYNC';
    Prefix.Information := 'SYNC_DrawMarker input fixture';
    Prefix.Items := @EmptyItems;
    Prefix.Func_Proc_Video := PrefixVideo;
    Log('register: prefix');
    Table^.RegisterFilterPlugin(@Prefix);
    Log('register: probe');
    Table^.RegisterFilterPlugin(@Probe);
    Log('register: done');
  except
    on E: Exception do Log('register exception: ' + E.Message);
  end;
end;

procedure UninitializePlugin; cdecl;
begin
  try
    if Sink <> 0 then DeallocateHWnd(Sink);
    Dispatcher.Free;
    Capture.Free;
    LogLock.Free;
  except
  end;
end;

exports RequiredVersion, InitializePlugin, RegisterPlugin, UninitializePlugin;

begin
end.
