program DrawMarker_Smoke;

{$APPTYPE CONSOLE}
{$R+}
{$Q+}

uses
  Winapi.Windows, System.SysUtils, System.Math, System.Types,
  AviUtl2FilterTypes in '..\Source\Lib\AviUtl2FilterTypes.pas',
  DrawMarker_Capture in '..\Source\Plugin\Filter\DrawMarker_Capture.pas',
  DrawMarker_Model in '..\Source\Common\DrawMarker_Model.pas',
  DrawMarker_Curves in '..\Source\Common\DrawMarker_Curves.pas',
  DrawMarker_Renderer in '..\Source\Common\DrawMarker_Renderer.pas';

type
  TRequired = function: Cardinal; cdecl;
  TInitialize = function(Version: Cardinal): Byte; cdecl;
  TRegister = procedure(Host: PHOST_APP_TABLE); cdecl;
  TShutdown = procedure; cdecl;

var
  Captures, Uploads, Composites: Integer;
  LastUpload: TRGBAPixels;
  EditHandle: TEDIT_HANDLE;
  FilterTable: PFILTER_PLUGIN_TABLE;

procedure Check(Condition: Boolean; const Description: string);
begin
  if not Condition then raise Exception.Create(Description);
end;

function MakeDocument: TMarkerDocument;
begin
  Result.Width := 320;
  Result.Height := 180;
  SetLength(Result.Strokes, 2);
  with Result.Strokes[0] do
  begin
    Style := DefaultStyle(pkMarker);
    Input := ikPen;
    SetLength(Samples, 2);
    Samples[0].Position := PointF(25, 40);
    Samples[0].Pressure := 0.2;
    Samples[1].Position := PointF(120, 40);
    Samples[1].Milliseconds := 880;
    Samples[1].Pressure := 1;
  end;
  with Result.Strokes[1] do
  begin
    Style := DefaultStyle(pkNormal);
    Input := ikMouse;
    SetLength(Anchors, 2);
    Anchors[0].Position := PointF(25, 100);
    Anchors[0].OutHandle := PointF(40, 0);
    Anchors[1].Position := PointF(200, 100);
    Anchors[1].InHandle := PointF(-40, 0);
  end;
end;

procedure TestModel;
var Doc, Reloaded: TMarkerDocument; Paths: TMarkerPaths; Renderer: TMarkerRenderer;
  First, Second, Pixels: TRGBAPixels; I: Integer; Pen: TPenKind; JSON: string;
begin
  Doc := MakeDocument;
  JSON := WriteDocument(Doc);
  Reloaded := ReadDocument(JSON, 10, 20);
  Check(WriteDocument(Reloaded) = JSON, 'JSON roundtrip');
  Check(Reloaded.Width = 320, 'Reference scene size');
  Paths := BuildPaths(Doc);
  Check(Abs(Paths[1].Start - 0.88) < 1E-6, 'Pen time before curve start');
  Check(Abs(Paths[1].Duration - 1.75) < 1E-5, 'Mouse distance timing');
  SplitCurve(Doc.Strokes[1].Anchors, 0, 0.43);
  Check(Length(Doc.Strokes[1].Anchors) = 3, 'Insert a vertex');
  Check(Abs(BuildPath(Doc.Strokes[1], 320).Duration - Paths[1].Duration) < 1E-5,
    'Style and distance of split straight curve');
  Renderer := TMarkerRenderer.Create;
  try
    First := Copy(Renderer.Render(Paths, 320, 180, 320, 180, 0.44));
    Check(First[40 * 320 + 35].A = 107, 'Opacity of an individual marker stroke');
    Check(First[40 * 320 + 115].A = 0, 'Pen endpoint has not appeared yet');
    Check(First[100 * 320 + 35].A = 0, 'Next stroke has not started');
    Pixels := Renderer.Render(Paths, 320, 180, 320, 180, 6);
    Check(Pixels[40 * 320 + 115].A = 107, 'Pen endpoint is retained after completion');
    Check(Pixels[100 * 320 + 35].A = 255, 'Mouse stroke renders after pen stroke');
    Check(Pixels[0].A = 0, 'Transparent background');
    Pixels := nil;
    Second := Renderer.Render(Paths, 320, 180, 320, 180, 0.44);
    Check(CompareMem(@First[0], @Second[0], Length(First) * SizeOf(TPIXEL_RGBA)),
      'Reverse seek renders the same pixels');
    Second := nil;
    for Pen := Low(TPenKind) to High(TPenKind) do
    begin
      Doc.Strokes[1].Style := DefaultStyle(Pen);
      Paths := BuildPaths(Doc);
      Pixels := Renderer.Render(Paths, 320, 180, 320, 180, 6);
      I := 0;
      while (I < 320) and (Pixels[100 * 320 + I].A = 0) do Inc(I);
      Check(I < 320, 'Every pen kind makes a visible mouse stroke');
      if Pen = pkDash then Check(Pixels[100 * 320 + 48].A = 0, 'Dash includes a gap');
      if Pen = pkGlow then Check(Pixels[107 * 320 + 70].A > 0, 'Glow outside the core');
      if Pen = pkBrush then Check(Pixels[105 * 320 + 110].A > Pixels[105 * 320 + 27].A,
        'Mouse brush uses variable line width');
    end;
  finally
    Renderer.Free;
  end;
  Writeln('Model, stroke styles, JSON, curve split, and absolute timeline PASS');
end;

procedure TestCaptureMatching;
var Capture: TInputCapture; Target: TMarkerTarget; Video: TFILTER_PROC_VIDEO;
  Scene: TSCENE_INFO; Obj: TOBJECT_INFO;
begin
  Capture := TInputCapture.Create;
  try
    Video := Default(TFILTER_PROC_VIDEO);
    Obj := Default(TOBJECT_INFO);
    Scene := Default(TSCENE_INFO);
    Target := Default(TMarkerTarget);
    Target.Scene := 3;
    Target.Frame := 19;
    Target.ObjectLayer := 2;
    Target.ObjectID := 42;
    Target.EffectID := 101;
    Scene.ID := 3;
    Scene.OriginID := 3;
    Video.Scene := @Scene;
    Obj.Layer := 2;
    Obj.ID := 42;
    Obj.EffectID := 101;
    Obj.OriginFrame := 18;
    Video.Object_ := @Obj;
    Capture.Arm(Target, 5);
    Check(Capture.Claim(@Video) = 0, 'Wrong timeline frame');
    Obj.OriginFrame := 19;
    Scene.Flag := 1;
    Check(Capture.Claim(@Video) = 0, 'Ignore reference frame');
    Scene.Flag := 0;
    Obj.EffectID := 102;
    Check(Capture.Claim(@Video) = 0, 'Wrong effect ID');
    Obj.EffectID := 101;
    Check(Capture.Claim(@Video) = 5, 'Matching request');
    Check(Capture.Claim(@Video) = 0, 'Each request is consumed once');
    Capture.Arm(Target, 6);
    Capture.Cancel(5);
    Check(Capture.Claim(@Video) = 6, 'Old cancellation cannot clear the next request');
    Capture.Arm(Target, 7);
    Capture.Cancel(7);
    Check(Capture.Claim(@Video) = 0, 'Cancelled request does not read');
  finally
    Capture.Free;
  end;
  Writeln('Capture request matching and consumption PASS');
end;

procedure RecordInformation(Information: LPCWSTR); cdecl;
begin
  Check(Information <> nil, 'Plugin information');
end;

procedure RecordTable(Table: PFILTER_PLUGIN_TABLE); cdecl;
begin
  FilterTable := Table;
end;

function GetMockHandle: PEDIT_HANDLE; cdecl;
begin
  Result := @EditHandle;
end;

function GetMockWindow: NativeUInt; cdecl;
begin
  Result := 0;
end;

procedure CountReadback(Buffer: PPIXEL_RGBA); cdecl;
begin
  Inc(Captures);
end;

function GetMockBlend(Mode: Integer): Pointer; cdecl;
begin
  Result := nil;
  if Mode = 2 then Result := Pointer(1);
end;

function CopyUpload(Name: LPCWSTR; Buffer: Pointer;
  Width, Height, Pitch, PixelFormat: Integer): Boolean; cdecl;
begin
  Result := (Name <> nil) and (PixelFormat = 28) and (Pitch = Width * 4);
  if Result then
  begin
    Inc(Uploads);
    SetLength(LastUpload, Width * Height);
    Move(Buffer^, LastUpload[0], Length(LastUpload) * SizeOf(TPIXEL_RGBA));
  end;
end;

function RecordShader(Code: Pointer; CodeSize: Integer; Target: LPCWSTR; Resources: Pointer;
  ResourceCount: Integer; Constants: Pointer; ConstantSize: Integer; Blend, Sampler: Pointer): Boolean; cdecl;
begin
  Result := (Code <> nil) and (CodeSize > 20) and (Target = nil) and
    (ResourceCount = 1) and (Resources <> nil) and (Blend = Pointer(1));
  if Result then Inc(Composites);
end;

procedure TestPlugin(const FileName: string);
var
  Handle: HMODULE;
  Required: TRequired; Initialize: TInitialize; RegisterPlugin: TRegister; Shutdown: TShutdown;
  Host: THOST_APP_TABLE;
  Video: TFILTER_PROC_VIDEO;
  Obj: TOBJECT_INFO;
  Data: PFILTER_ITEM_STRING;
  Speed: PFILTER_ITEM_TRACK;
  JSON: string;
begin
  Handle := LoadLibrary(PChar(FileName));
  Check(Handle <> 0, 'Loading production AUX2');
  try
    Required := GetProcAddress(Handle, 'RequiredVersion');
    Initialize := GetProcAddress(Handle, 'InitializePlugin');
    RegisterPlugin := GetProcAddress(Handle, 'RegisterPlugin');
    Shutdown := GetProcAddress(Handle, 'UninitializePlugin');
    Check(Assigned(Required) and Assigned(Initialize) and Assigned(RegisterPlugin) and Assigned(Shutdown),
      'SDK exports');
    Check((Required() = 2011000) and (Initialize(2010900) = 0), 'Host version gate');
    Check(Initialize(2011000) = 1, 'Production shader and dispatch initialization');
    try
      Host := Default(THOST_APP_TABLE);
      Host.SetPluginInformation := RecordInformation;
      Host.RegisterFilterPlugin := RecordTable;
      Host.CreateEditHandle := GetMockHandle;
      EditHandle.GetHostAppWindow := GetMockWindow;
      RegisterPlugin(@Host);
      Check(FilterTable <> nil, 'Production filter registration');
      Check((FilterTable^.Flag and FILTER_FLAG_FILTER) <> 0, 'Filter object support');
      Speed := PFILTER_ITEM_TRACK(FilterTable^.Items^);
      Check((Speed^.Value = 100) and SameValue(Speed^.Step, 0.01), 'Speed default and precision');
      Data := PFILTER_ITEM_STRING(PPointer(PByte(FilterTable^.Items) + 2 * SizeOf(Pointer))^);
      JSON := WriteDocument(MakeDocument);
      Data^.Value := PChar(JSON);
      Obj := Default(TOBJECT_INFO);
      Obj.Width := 320;
      Obj.Height := 180;
      Video := Default(TFILTER_PROC_VIDEO);
      Video.Object_ := @Obj;
      Video.GetImageData := CountReadback;
      Video.SetImageResourceData := CopyUpload;
      Video.GetBlendState := GetMockBlend;
      Video.ExecPixelshaderData := RecordShader;
      Video.UserData := FilterTable^.Func_Create(1);
      Check(Video.UserData <> nil, 'Effect session');
      try
        Obj.Time := 0;
        Check(FilterTable^.Func_Proc_Video(@Video) = 1, 'Frame zero');
        Check(Uploads = 0, 'Frame zero leaves input unchanged');
        Obj.Time := 0.44;
        Check(FilterTable^.Func_Proc_Video(@Video) = 1, 'Render incomplete stroke');
        Check((Uploads = 1) and (Composites = 1), 'Production shader gets overlay pixels');
        Check((LastUpload[40 * 320 + 75].A > 0) and (LastUpload[40 * 320 + 104].A = 0), '100% speed');
        Speed^.Value := 50;
        FilterTable^.Func_Proc_Video(@Video);
        Check(LastUpload[40 * 320 + 75].A = 0, '50% speed');
        Speed^.Value := 200;
        FilterTable^.Func_Proc_Video(@Video);
        Check(LastUpload[40 * 320 + 116].A > 0, '200% speed');
        Check(Captures = 0, 'No GetImageData in normal playback');
      finally
        FilterTable^.Func_Destroy(1, Video.UserData);
      end;
    finally
      Shutdown();
    end;
  finally
    FreeLibrary(Handle);
  end;
  Writeln('Production AUX2 ABI, shader setup, overlay and speed PASS');
end;

begin
  try
    TestModel;
    TestCaptureMatching;
    TestPlugin(ParamStr(1));
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
