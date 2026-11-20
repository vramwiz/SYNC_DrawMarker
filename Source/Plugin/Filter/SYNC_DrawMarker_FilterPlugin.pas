unit SYNC_DrawMarker_FilterPlugin;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

interface

uses AviUtl2FilterTypes;

const
  RequiredHost = 2011000; // v2.1.10: FILTER_ITEM_BUTTON.callback2 / object・effect ID
  PluginName = '手描きマーカー';
  PluginInfo = '手描きマーカー / SYNC_DrawMarker v0.1.0';

procedure InitializeMarker;
procedure RegisterMarker(Table: PHOST_APP_TABLE);
procedure ShutdownMarker;

implementation

uses
  System.SysUtils, System.Classes, System.Math, System.SyncObjs, System.UITypes,
  Winapi.Windows, Winapi.Messages, Winapi.D3DCommon, Winapi.D3DCompiler,
  Vcl.Dialogs, PluginFilterTable, DrawMarker_Capture, DrawMarker_Model,
  DrawMarker_Curves, DrawMarker_Renderer, DrawMarker_Editor;

const
  JsonItemName = '描画データ';
  WM_CAPTURE_READY = WM_APP + 153;
  CaptureDeadline = 2500;
  PSCode: AnsiString =
    'Texture2D<float4> ink: register(t0);' +
    'float4 psmain(float4 p: SV_Position): SV_Target { return ink.Load(int3(int2(p.xy),0)); }';

type
  TMarkerSession = class
  private
    FLock: TCriticalSection;
    FRenderer: TMarkerRenderer;
    FJSON: string;
    FDocument: TMarkerDocument;
    FPaths: TMarkerPaths;
    FDuration, FLastTime: Double;
    FWidth, FHeight: Integer;
    FOutput: TRGBAPixels;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Render(Video: PFILTER_PROC_VIDEO; const JSON: string; Speed: Double);
  end;

  TEditorRequest = record
    Target: TMarkerTarget;
    Original, Serialized: string;
    SceneWidth, SceneHeight: Integer;
    Written: Boolean;
  end;

  TMarkerHost = class
  private
    FHandle: PEDIT_HANDLE;
    FWindow: HWND;
    FOwnerWindow: HWND;
    FCapture: TInputCapture;
    FReplyLock: TCriticalSection;
    FReply: TMarkerCapture;
    FWaitingToken: NativeUInt; // Protected with FReplyLock.
    FSerial, FPendingToken: NativeUInt;
    FRequest: TEditorRequest;
    FOpening: Boolean;
    FBaseline: string;
    procedure WindowProc(var Message: TMessage);
    procedure ShowEditor;
    function Save(const JSON: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure BeginEditor(Edit: PEDIT_SECTION; Obj: OBJECT_HANDLE; Effect: PWideChar);
    procedure CaptureInput(Video: PFILTER_PROC_VIDEO);
  end;

var
  EditorHost: TMarkerHost;
  SpeedTrack: TFILTER_ITEM_TRACK;
  JsonItem: TFILTER_ITEM_STRING;
  EditorButton: TFILTER_ITEM_BUTTON;
  Shader: ID3DBlob;

function ItemValue(Edit: PEDIT_SECTION; Effect: EFFECT_HANDLE): string;
var P: PAnsiChar;
begin
  P := Edit^.GetEffectItemValue(Effect, JsonItemName);
  if P = nil then Exit('');
  Result := string(UTF8String(P));
end;

procedure StoreJSON(Param: Pointer; Edit: PEDIT_SECTION); cdecl;
type PRequest = ^TEditorRequest;
var Request: PRequest; Obj: OBJECT_HANDLE; Effect: EFFECT_HANDLE; Value, Previous: UTF8String;
begin
  Request := Param;
  try
    if (Edit^.Info = nil) or (PEDIT_INFO(Edit^.Info)^.SceneID <> Request^.Target.Scene) then Exit;
    Obj := Edit^.FindObject(Request^.Target.ObjectLayer, Request^.Target.ObjectStart);
    if (Obj = nil) or (Edit^.GetObjectID(Obj) <> Request^.Target.ObjectID) then Exit;
    Effect := Edit^.FindEffect(Obj, PChar(Request^.Target.EffectName));
    if (Effect = nil) or (Edit^.GetEffectID(Effect) <> Request^.Target.EffectID) then Exit;
    if ItemValue(Edit, Effect) <> Request^.Original then Exit;
    Value := UTF8String(Request^.Serialized);
    if not Edit^.SetEffectItemValue(Effect, JsonItemName, PAnsiChar(Value)) then Exit;
    if ItemValue(Edit, Effect) <> Request^.Serialized then
    begin
      Previous := UTF8String(Request^.Original);
      Edit^.SetEffectItemValue(Effect, JsonItemName, PAnsiChar(Previous));
      Exit;
    end;
    Request^.Written := True;
  except
    on E: Exception do OutputDebugString(PChar('SYNC_DrawMarker save: ' + E.Message));
  end;
end;

constructor TMarkerHost.Create;
begin
  inherited;
  FCapture := TInputCapture.Create;
  FReplyLock := TCriticalSection.Create;
  FWindow := AllocateHWnd(WindowProc);
end;

destructor TMarkerHost.Destroy;
begin
  if FWindow <> 0 then
  begin
    KillTimer(FWindow, 1);
    DeallocateHWnd(FWindow);
  end;
  FCapture.Free;
  FReplyLock.Free;
  inherited;
end;

procedure TMarkerHost.BeginEditor(Edit: PEDIT_SECTION; Obj: OBJECT_HANDLE; Effect: PWideChar);
var Target: TMarkerTarget; Handle: EFFECT_HANDLE; Info: PEDIT_INFO;
begin
  if FOpening or (FPendingToken <> 0) then Exit;
  if (FHandle = nil) or not ReadTarget(Edit, Obj, Effect, Target, Handle) then Exit;
  if (FHandle^.GetEditState() <> 0) or (Target.Frame < Target.ObjectStart) or
    (Target.Frame > Target.ObjectEnd) then
    raise EInvalidOp.Create('再生を止め、対象オブジェクトの範囲内にカーソルを置いてください。');
  Info := PEDIT_INFO(Edit^.Info);
  FRequest.Target := Target;
  FRequest.SceneWidth := Info^.Width;
  FRequest.SceneHeight := Info^.Height;
  FRequest.Original := ItemValue(Edit, Handle);
  Inc(FSerial);
  FPendingToken := FSerial;
  FReplyLock.Acquire;
  try
    FWaitingToken := FPendingToken;
  finally
    FReplyLock.Release;
  end;
  FCapture.Arm(Target, FPendingToken);
  try
    if SetTimer(FWindow, 1, CaptureDeadline, nil) = 0 then RaiseLastOSError;
    // No shared lock is held across this call. The video callback may run immediately.
    Edit^.SetCursorLayerFrame(Target.CursorLayer, Target.Frame);
  except
    FCapture.Cancel(FPendingToken);
    FPendingToken := 0;
    FReplyLock.Acquire;
    try
      FWaitingToken := 0;
      FReply := Default(TMarkerCapture);
    finally
      FReplyLock.Release;
    end;
    KillTimer(FWindow, 1);
    raise;
  end;
end;

procedure TMarkerHost.CaptureInput(Video: PFILTER_PROC_VIDEO);
var Token: NativeUInt; Frame: TMarkerCapture;
begin
  Token := FCapture.Claim(Video);
  if Token = 0 then Exit;
  if not CopyFilterInput(Video, Token, Frame) then Exit;
  FReplyLock.Acquire;
  try
    // Replies may arrive after an earlier request timed out.
    if Frame.Token <> FWaitingToken then Exit;
    FReply := Frame;
  finally
    FReplyLock.Release;
  end;
  PostMessage(FWindow, WM_CAPTURE_READY, WPARAM(Token), 0);
end;

procedure TMarkerHost.WindowProc(var Message: TMessage);
begin
  try
    case Message.Msg of
      WM_CAPTURE_READY:
        if (FPendingToken <> 0) and (WPARAM(FPendingToken) = Message.WParam) then ShowEditor;
      WM_TIMER: if (Message.WParam = 1) and (FPendingToken <> 0) then ShowEditor;
    else
      Message.Result := DefWindowProc(FWindow, Message.Msg, Message.WParam, Message.LParam);
    end;
  except
    on E: Exception do MessageDlg(E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TMarkerHost.ShowEditor;
var Frame: TMarkerCapture; Document: TMarkerDocument; W, H: Integer;
begin
  KillTimer(FWindow, 1);
  FCapture.Cancel(FPendingToken);
  FReplyLock.Acquire;
  try
    if FReply.Token = FPendingToken then Frame := FReply
    else Frame := Default(TMarkerCapture);
    FReply := Default(TMarkerCapture);
    FWaitingToken := 0;
  finally
    FReplyLock.Release;
  end;
  FPendingToken := 0;
  FOpening := True;
  try
    W := Frame.Width;
    H := Frame.Height;
    if Length(Frame.Pixels) = 0 then
    begin
      W := EnsureRange(FRequest.SceneWidth, 1, 16384);
      H := EnsureRange(FRequest.SceneHeight, 1, 16384);
    end;
    Document := ReadDocument(FRequest.Original, W, H);
    FBaseline := WriteDocument(Document);
    OpenMarkerEditor(FOwnerWindow, Document, Frame, Save);
  finally
    FRequest := Default(TEditorRequest);
    FBaseline := '';
    FOpening := False;
  end;
end;

function TMarkerHost.Save(const JSON: string): Boolean;
begin
  if JSON = FBaseline then Exit(True);
  FRequest.Serialized := JSON;
  FRequest.Written := False;
  Result := FHandle^.CallEditSectionParam(@FRequest, StoreJSON) and FRequest.Written;
  if not Result then raise EInvalidOp.Create('AviUtl2 に反映できません。対象のオブジェクトと編集状態を確認してください。');
end;

constructor TMarkerSession.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FRenderer := TMarkerRenderer.Create;
end;

destructor TMarkerSession.Destroy;
begin
  FRenderer.Free;
  FLock.Free;
  inherited;
end;

procedure TMarkerSession.Render(Video: PFILTER_PROC_VIDEO; const JSON: string; Speed: Double);
const
  MarkerResource: PWideChar = 'resource:SYNC_DrawMarker';
  FormatRGBA = 28;
  BlendDraw = 2;
var W, H: Integer; Elapsed: Double; Blend: Pointer;
begin
  W := Video^.Object_^.Width;
  H := Video^.Object_^.Height;
  if (JSON = '') or (W <= 0) or (H <= 0) or
    not Assigned(Video^.SetImageResourceData) or not Assigned(Video^.ExecPixelshaderData) or
    not Assigned(Video^.GetBlendState) then Exit;
  if IsNan(Speed) or IsInfinite(Speed) then Speed := 100;
  Elapsed := Video^.Object_^.Time * EnsureRange(Speed, 0.01, 4000.0) / 100;
  if Elapsed <= 0 then Exit;
  FLock.Acquire;
  try
    if JSON <> FJSON then
    begin
      FJSON := JSON;
      FPaths := nil;
      FLastTime := -1;
      FDocument := ReadDocument(JSON, W, H);
      FPaths := BuildPaths(FDocument);
      FDuration := 0;
      if Length(FPaths) > 0 then FDuration := FPaths[High(FPaths)].Start + FPaths[High(FPaths)].Duration;
    end;
    if Length(FPaths) = 0 then Exit;
    Elapsed := Min(Elapsed, FDuration);
    if (Elapsed <> FLastTime) or (W <> FWidth) or (H <> FHeight) then
    begin
      FOutput := nil;
      FOutput := FRenderer.Render(FPaths, FDocument.Width, FDocument.Height, W, H, Elapsed);
      FWidth := W;
      FHeight := H;
      FLastTime := Elapsed;
    end;
    if Length(FOutput) = 0 then Exit;
    Blend := Video^.GetBlendState(BlendDraw);
    if (Blend <> nil) and
      Video^.SetImageResourceData(MarkerResource, @FOutput[0], W, H, W * SizeOf(TPIXEL_RGBA), FormatRGBA) then
      Video^.ExecPixelshaderData(Shader.GetBufferPointer, Shader.GetBufferSize,
        nil, @MarkerResource, 1, nil, 0, Blend, nil);
  finally
    FLock.Release;
  end;
end;

function RenderMarker(Video: PFILTER_PROC_VIDEO): Byte; cdecl;
begin
  Result := 1;
  if (Video = nil) or (Video^.Object_ = nil) then Exit;
  try
    EditorHost.CaptureInput(Video);
  except
    on E: Exception do OutputDebugString(PChar('SYNC_DrawMarker capture: ' + E.Message));
  end;
  try
    if Video^.UserData <> nil then
      TMarkerSession(Video^.UserData).Render(Video, string(JsonItem.Value), SpeedTrack.Value);
  except
    on E: Exception do OutputDebugString(PChar('SYNC_DrawMarker video: ' + E.Message));
  end;
end;

function CreateMarker(EffectID: Int64): Pointer; cdecl;
begin
  Result := nil;
  try
    Result := TMarkerSession.Create;
  except
  end;
end;

procedure DestroyMarker(EffectID: Int64; UserData: Pointer); cdecl;
begin
  try
    TMarkerSession(UserData).Free;
  except
  end;
end;

procedure ClickEditor(Edit: PEDIT_SECTION; Obj: OBJECT_HANDLE; Effect, Item: PWideChar); cdecl;
begin
  try
    EditorHost.BeginEditor(Edit, Obj, Effect);
  except
    on E: Exception do
      try
        MessageDlg(E.Message, mtError, [mbOK], 0);
      except
      end;
  end;
end;

procedure InitializeMarker;
var Errors: ID3DBlob; Status: HRESULT;
begin
  Status := D3DCompile(PAnsiChar(PSCode), Length(PSCode), 'DrawMarker', nil, nil,
    'psmain', 'ps_5_0', 0, 0, Shader, Errors);
  if Status < 0 then raise EInvalidOp.Create('手描きマーカーの描画シェーダーを初期化できません。');
  EditorHost := TMarkerHost.Create;
end;

procedure RegisterMarker(Table: PHOST_APP_TABLE);
var FilterTable: PFILTER_PLUGIN_TABLE;
begin
  EditorHost.FHandle := Table^.CreateEditHandle();
  EditorHost.FOwnerWindow := HWND(EditorHost.FHandle^.GetHostAppWindow());
  SetupPluginTable(FILTER_FLAG_VIDEO or FILTER_FLAG_FILTER or FILTER_FLAG_USERDATA,
    PluginName, 'SYNC', PluginInfo, RenderMarker, nil);
  AddTrack(SpeedTrack, '描画速度', 100, 0.01, 4000, 0.01);
  AddButton(EditorButton, '描画を編集', ClickEditor);
  AddString(JsonItem, JsonItemName, '');
  FilterTable := GetPluginTable;
  FilterTable^.Func_Create := CreateMarker;
  FilterTable^.Func_Destroy := DestroyMarker;
  Table^.RegisterFilterPlugin(FilterTable);
end;

procedure ShutdownMarker;
begin
  FreeAndNil(EditorHost);
  Shader := nil;
end;

end.
