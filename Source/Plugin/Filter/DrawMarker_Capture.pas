unit DrawMarker_Capture;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// Host pixel buffers are borrowed only during func_proc_video.

interface

uses AviUtl2FilterTypes, System.SyncObjs;

type
  TMarkerTarget = record
    Scene, Frame, CursorLayer, ObjectLayer, ObjectStart, ObjectEnd: Integer;
    ObjectID, EffectID: Int64;
    EffectName: string;
  end;

  TMarkerCapture = record
    Token: NativeUInt;
    Width, Height: Integer;
    Pixels: TRGBAPixels;
  end;

  TInputCapture = class
  private
    FLock: TCriticalSection;
    FArmed: Integer;
    FToken: NativeUInt;
    FTarget: TMarkerTarget;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Arm(const Target: TMarkerTarget; Token: NativeUInt);
    procedure Cancel(Token: NativeUInt);
    function Claim(Video: PFILTER_PROC_VIDEO): NativeUInt;
  end;

function ReadTarget(Edit: PEDIT_SECTION; Obj: OBJECT_HANDLE; Effect: PWideChar;
  out Target: TMarkerTarget; out EffectHandle: EFFECT_HANDLE): Boolean;
function CopyFilterInput(Video: PFILTER_PROC_VIDEO; Token: NativeUInt;
  out Frame: TMarkerCapture): Boolean;

implementation

uses System.SysUtils;

function ReadTarget(Edit: PEDIT_SECTION; Obj: OBJECT_HANDLE; Effect: PWideChar;
  out Target: TMarkerTarget; out EffectHandle: EFFECT_HANDLE): Boolean;
var
  Info: PEDIT_INFO;
  Location: TOBJECT_LAYER_FRAME;
begin
  Result := False;
  EffectHandle := nil;
  if (Edit = nil) or (Edit^.Info = nil) or (Obj = nil) or (Effect = nil) then Exit;
  EffectHandle := Edit^.FindEffect(Obj, Effect);
  if EffectHandle = nil then Exit;
  Info := PEDIT_INFO(Edit^.Info);
  Location := Edit^.GetObjectLayerFrame(Obj);
  Target.Scene := Info^.SceneID;
  Target.Frame := Info^.Frame;
  Target.CursorLayer := Info^.Layer;
  Target.ObjectLayer := Location.Layer;
  Target.ObjectStart := Location.StartFrame;
  Target.ObjectEnd := Location.EndFrame;
  Target.ObjectID := Edit^.GetObjectID(Obj);
  Target.EffectID := Edit^.GetEffectID(EffectHandle);
  Target.EffectName := Effect;
  Result := (Target.ObjectID <> 0) and (Target.EffectID <> 0);
end;

constructor TInputCapture.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
end;

destructor TInputCapture.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TInputCapture.Arm(const Target: TMarkerTarget; Token: NativeUInt);
begin
  FLock.Acquire;
  try
    FTarget := Target;
    FToken := Token;
    TInterlocked.Exchange(FArmed, 1);
  finally
    FLock.Release;
  end;
end;

procedure TInputCapture.Cancel(Token: NativeUInt);
begin
  FLock.Acquire;
  try
    if FToken = Token then TInterlocked.Exchange(FArmed, 0);
  finally
    FLock.Release;
  end;
end;

function TInputCapture.Claim(Video: PFILTER_PROC_VIDEO): NativeUInt;
begin
  Result := 0;
  if (TInterlocked.CompareExchange(FArmed, 0, 0) = 0) or
    (Video = nil) or (Video^.Scene = nil) or (Video^.Object_ = nil) then Exit;
  FLock.Acquire;
  try
    if (FArmed <> 0) and (Video^.Scene^.ID = FTarget.Scene) and
      (Video^.Scene^.OriginID = FTarget.Scene) and
      ((Video^.Scene^.Flag and 1) = 0) and
      (Video^.Object_^.OriginFrame = FTarget.Frame) and
      (Video^.Object_^.Layer = FTarget.ObjectLayer) and
      (Video^.Object_^.ID = FTarget.ObjectID) and
      (Video^.Object_^.EffectID = FTarget.EffectID) then
    begin
      TInterlocked.Exchange(FArmed, 0);
      Result := FToken;
    end;
  finally
    FLock.Release;
  end;
end;

function CopyFilterInput(Video: PFILTER_PROC_VIDEO; Token: NativeUInt;
  out Frame: TMarkerCapture): Boolean;
begin
  Frame.Token := Token;
  Frame.Width := Video^.Object_^.Width;
  Frame.Height := Video^.Object_^.Height;
  Result := Assigned(Video^.GetImageData) and (Frame.Width > 0) and
    (Frame.Height > 0) and (Int64(Frame.Width) * Frame.Height <= 40 * 1024 * 1024);
  if not Result then Exit;
  SetLength(Frame.Pixels, Frame.Width * Frame.Height);
  Video^.GetImageData(@Frame.Pixels[0]);
end;

end.
