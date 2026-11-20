unit DrawMarker_Editor;

interface

uses
  Winapi.Windows, Winapi.Messages, System.Types, System.Classes, System.Generics.Collections,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  DrawMarker_Model, DrawMarker_Curves, DrawMarker_Renderer, DrawMarker_Capture;

type
  TMarkerSave = function(const JSON: string): Boolean of object;

procedure OpenMarkerEditor(OwnerWindow: HWND; const Document: TMarkerDocument;
  const Background: TMarkerCapture; Save: TMarkerSave);

implementation

uses System.SysUtils, System.Math, System.UITypes, Vcl.Buttons, Vcl.Dialogs, Vcl.Menus,
  Vcl.Themes, Vcl.Styles, AviUtl2FilterTypes, HorizontalTrackBarControl,
  ColorPickerHueBar, ColorPickerSVArea, ColorPickerColorMath, MapRakuColorCode;

const
  MarkerStyleName = 'Windows Modern Dark';
  ChromeColor = TColor($00282422);
  CanvasColor = TColor($001A1817);
  TextColor = TColor($00ECEBE8);

type
  TMarkerEditor = class;
  TMarkerCanvas = class(TCustomControl)
  private
    FEditor: TMarkerEditor;
  protected
    procedure Paint; override;
    procedure WndProc(var Message: TMessage); override;
  end;

  TDragPart = (dpNone, dpStroke, dpVertex, dpIncoming, dpOutgoing);
  TMarkerTool = (mtSelect, mtContinuous, mtFreehand);

  TMarkerToolButton = class(TSpeedButton)
  private
    procedure RefreshGlyph(PPI: Integer);
  protected
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
  end;

  TMarkerColorDock = class(TPanel)
  private
    FTitle: TLabel;
    FHue: TColorPickerHueBar;
    FArea: TColorPickerSVArea;
    FSample: TShape;
    FCode: TEdit;
  protected
    procedure AlignControls(AControl: TControl; var Rect: TRect); override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

  TMarkerEditor = class(TForm)
  private
    FOwnerWindow: HWND;
    FSave: TMarkerSave;
    FView: TMarkerCanvas;
    FContent: TRect;
    FBackground: TMarkerCapture;
    FBitmap: TBitmap;
    FRenderer: TMarkerRenderer;
    FDoc: TMarkerDocument;
    FPaths: TMarkerPaths;
    FPathsDirty: Boolean;
    FRenderValid, FPreviewActive, FPreviewFreehand: Boolean;
    FUndo, FRedo: TList<TMarkerDocument>;
    FSelected, FVertex: Integer;
    FDragging: TDragPart;
    FBeforeDrag: TMarkerDocument;
    FDragOrigin: TPointF;
    FDragChanged: Boolean;
    FTool: TMarkerTool;
    FStyle: TStrokeStyle;
    FPending: TArray<TCurveAnchor>;
    FLastCurveClick: TPoint;
    FLastCurveClickTime: UInt64;
    FStrokeSamples: TList<TPenSample>;
    FMouseDrawing: Boolean;
    FPenID, FStrokeStart: Cardinal;
    FHover: TPointF;
    FHovering: Boolean;
    FSync: Boolean;
    FToolButtons: array[TMarkerTool] of TSpeedButton;
    FUndoItem, FRedoItem, FDeleteItem, FKindItem: TMenuItem;
    FPenPicker: TComboBox;
    FSize, FOpacity: THorizontalTrackBarControl;
    FSizeValue, FOpacityValue: TLabel;
    FColorDock: TMarkerColorDock;
    FStyleGesture: TControl;
    FRecordedStyleGesture: Boolean;
    FStatus: TLabel;
    procedure SetStatus;
    procedure SyncControls;
    procedure Changed;
    procedure EnsurePaths;
    procedure BeginChange;
    procedure PushUndo(const Before: TMarkerDocument);
    procedure AddStroke(const Stroke: TMarkerStroke);
    procedure CurveClick(const P: TPoint);
    procedure CurveHover(const P: TPoint);
    procedure FinishCurve;
    procedure AddFreehandSample(const P: TPoint; Timestamp: Cardinal; Pressure: Single);
    procedure FinishFreehand(Cancel: Boolean);
    procedure SelectTool(Sender: TObject);
    procedure UndoClick(Sender: TObject);
    procedure RedoClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure KindClick(Sender: TObject);
    function CanInsertVertex(Segment: Integer; Parameter: Single): Boolean;
    function InsertVertex(Segment: Integer; Parameter: Single): Boolean;
    procedure ShowSelectionMenu(const Position: TPoint; Segment: Integer; Parameter: Single);
    procedure ColorChange(Sender: TObject);
    procedure ColorCodeExit(Sender: TObject);
    procedure ColorCodeKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure SyncColor(Color: Cardinal);
    procedure PenChange(Sender: TObject);
    procedure StyleChange(Sender: TObject);
    function CurrentStyle: TStrokeStyle;
    procedure ApplyStyle(Sender: TObject);
    procedure StyleMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure StyleMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure EditorClose(Sender: TObject; var Action: TCloseAction);
    procedure EditorKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ViewDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure ViewMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure ViewUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure EndDrag(Cancel: Boolean);
    function HandlePointer(const Msg: TMessage): Boolean;
    procedure AddPenHistory(ID: Cardinal; const Pen: POINTER_PEN_INFO; IncludeHistory: Boolean);
    function ToWorld(X, Y: Integer): TPointF;
    function ToView(const P: TPointF): TPoint;
    function HitSelectedPoint(X, Y: Integer; IncludeHandles: Boolean; out Index: Integer): TDragPart;
    procedure DrawView;
    procedure DrawSelection;
    procedure ComposePreview(const Markers: TRGBAPixels; Width, Height: Integer);
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  public
    constructor CreateEditor(OwnerWindow: HWND; const Document: TMarkerDocument;
      const Background: TMarkerCapture; Save: TMarkerSave);
    destructor Destroy; override;
    function IsShortCut(var Message: TWMKey): Boolean; override;
  end;

function PromotedMouse: Boolean;
begin
  Result := (NativeUInt(GetMessageExtraInfo) and $FFFFFF00) = $FF515700;
end;

procedure TMarkerCanvas.Paint;
begin
  if FEditor <> nil then FEditor.DrawView;
end;

procedure TMarkerCanvas.WndProc(var Message: TMessage);
begin
  if FEditor <> nil then
    case Message.Msg of
      WM_LBUTTONUP: FEditor.EndDrag(False);
      WM_POINTERDOWN, WM_POINTERUPDATE, WM_POINTERUP, WM_POINTERCAPTURECHANGED:
        if FEditor.HandlePointer(Message) then
        begin
          Message.Result := 0;
          Exit;
        end;
      WM_CAPTURECHANGED:
        begin
          FEditor.EndDrag(True);
          if FEditor.FMouseDrawing then FEditor.FinishFreehand(True);
        end;
      CM_MOUSELEAVE:
        begin
          FEditor.FHovering := False;
          if Length(FEditor.FPending) > 0 then Invalidate;
        end;
    end;
  inherited;
end;

procedure TMarkerToolButton.RefreshGlyph(PPI: Integer);
const GlyphSize = 18;
var GlyphPixels, SavedDC: Integer;
begin
  GlyphPixels := MulDiv(GlyphSize, PPI, 96);
  Glyph.SetSize(GlyphPixels, GlyphPixels);
  Glyph.TransparentColor := clFuchsia;
  with Glyph.Canvas do
  begin
    Brush.Color := clFuchsia;
    FillRect(Rect(0, 0, Glyph.Width, Glyph.Height));
    SavedDC := SaveDC(Handle);
    try
      SetMapMode(Handle, MM_ANISOTROPIC);
      SetWindowExtEx(Handle, GlyphSize, GlyphSize, nil);
      SetViewportExtEx(Handle, GlyphPixels, GlyphPixels, nil);
      Pen.Color := StyleServices(Self).GetSystemColor(clBtnText);
      Brush.Color := Pen.Color;
      Pen.Width := 1;
      case TMarkerTool(Tag) of
        mtSelect:
          Polygon([Point(4, 2), Point(4, 14), Point(7, 11), Point(10, 16),
            Point(12, 15), Point(9, 10), Point(14, 10)]);
        mtContinuous:
          begin
            Polyline([Point(3, 13), Point(8, 5), Point(12, 10), Point(15, 3)]);
            Rectangle(2, 12, 5, 15);
            Rectangle(7, 4, 10, 7);
            Rectangle(11, 9, 14, 12);
            Rectangle(14, 2, 17, 5);
          end;
        mtFreehand:
          begin
            Pen.Width := 2;
            PolyBezier([Point(2, 13), Point(9, -8), Point(8, 26), Point(16, 4)]);
          end;
      end;
    finally
      RestoreDC(Handle, SavedDC);
    end;
  end;
end;

procedure TMarkerToolButton.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  if isDpiChange then RefreshGlyph(M);
end;

constructor TMarkerColorDock.Create(AOwner: TComponent);
begin
  inherited;
  Width := 188;
  BevelOuter := bvNone;
  ParentBackground := False;
  StyleElements := StyleElements - [seClient];
  Color := ChromeColor;

  FTitle := TLabel.Create(Self);
  FTitle.Parent := Self;
  FTitle.Caption := '色';
  FTitle.StyleElements := FTitle.StyleElements - [seFont];
  FHue := TColorPickerHueBar.Create(Self);
  FHue.Parent := Self;
  FArea := TColorPickerSVArea.Create(Self);
  FArea.Parent := Self;
  FSample := TShape.Create(Self);
  FSample.Parent := Self;
  FSample.Pen.Color := TColor($00605B56);
  FCode := TEdit.Create(Self);
  FCode.Parent := Self;
  FCode.AutoSize := False;
  FCode.MaxLength := 24;
  FCode.Hint := '#RRGGBB または R,G,B';
  FCode.ShowHint := True;
end;

procedure TMarkerColorDock.AlignControls(AControl: TControl; var Rect: TRect);
var Inset, Gap, HueWidth, CodeHeight, PickerTop, CodeTop, AvailableWidth, Side: Integer;
begin
  inherited;
  if (FCode = nil) or (csDestroying in ComponentState) then Exit;
  Inset := ScaleValue(12);
  Gap := ScaleValue(8);
  HueWidth := ScaleValue(16);
  CodeHeight := ScaleValue(28);
  AvailableWidth := ClientWidth - 2 * Inset;
  FTitle.Left := Inset;
  FTitle.Top := Gap;
  PickerTop := FTitle.Top + FTitle.Height + Gap;
  Side := Max(1, Min(AvailableWidth - HueWidth - Gap,
    ClientHeight - PickerTop - CodeHeight - 2 * Gap));
  FArea.SetBounds(Inset, PickerTop, Side, Side);
  FHue.SetBounds(Inset + Side + Gap, PickerTop, HueWidth, Side);
  CodeTop := PickerTop + Side + Gap;
  FSample.SetBounds(Inset, CodeTop, CodeHeight, CodeHeight);
  FCode.SetBounds(Inset + CodeHeight + Gap, CodeTop,
    Max(1, AvailableWidth - CodeHeight - Gap), CodeHeight);
end;

constructor TMarkerEditor.CreateEditor(OwnerWindow: HWND; const Document: TMarkerDocument;
  const Background: TMarkerCapture; Save: TMarkerSave);
var
  Palette, Footer: TPanel;
  Settings: TFlowPanel;
  MainMenu: TMainMenu;
  EditMenu: TMenuItem;
  Kind: TPenKind;
  OwnerMonitor: TMonitor;
  WorkArea: TRect;
  W, H: Integer;

  procedure ToolButton(Tool: TMarkerTool; const Hint: string);
  var B: TMarkerToolButton;
  begin
    B := TMarkerToolButton.Create(Self);
    B.Tag := Ord(Tool);
    B.Parent := Palette;
    B.SetBounds(8, 8 + Ord(Tool) * 36, 32, 32);
    B.Flat := True;
    B.Hint := Hint;
    B.ShowHint := True;
    B.GroupIndex := 1;
    B.OnClick := SelectTool;
    B.RefreshGlyph(PixelsPerInch);
    FToolButtons[Tool] := B;
  end;

  function EditItem(const Caption: string; Key: Word; Shift: TShiftState;
    Action: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(MainMenu);
    Result.Caption := Caption;
    Result.ShortCut := ShortCut(Key, Shift);
    Result.OnClick := Action;
    EditMenu.Add(Result);
  end;

  function ChromePanel(Parent: TWinControl; Alignment: TAlign): TPanel;
  begin
    Result := TPanel.Create(Self);
    Result.Parent := Parent;
    Result.Align := Alignment;
    Result.BevelOuter := bvNone;
    Result.ParentBackground := False;
    Result.StyleElements := Result.StyleElements - [seClient];
    Result.Color := ChromeColor;
  end;

  procedure AddSetting(const Caption: string; Control: TControl; ControlWidth: Integer;
    Readout: TLabel);
  const RowHeight = 32;
  var Group: TPanel; L: TLabel;
  begin
    Group := ChromePanel(Settings, alNone);
    Group.Height := RowHeight;
    Group.AlignWithMargins := True;
    Group.Margins.SetBounds(0, 0, 12, 8);
    Group.Constraints.MinHeight := RowHeight;
    Group.Constraints.MaxHeight := RowHeight;
    L := TLabel.Create(Self);
    L.Parent := Group;
    L.Caption := Caption;
    L.StyleElements := L.StyleElements - [seFont];
    L.AlignWithMargins := True;
    L.Margins.SetBounds(0, 0, 8, 0);
    L.Layout := tlCenter;
    L.Align := alLeft;
    Control.Parent := Group;
    Control.SetBounds(Group.Width, 0, ControlWidth, Group.Height);
    if Control is TComboBox then
    begin
      Control.AlignWithMargins := True;
      Control.Margins.SetBounds(0, 4, 0, 0);
    end;
    Control.Align := alLeft;
    if Readout <> nil then
    begin
      Readout.Parent := Group;
      Readout.StyleElements := Readout.StyleElements - [seFont];
      Readout.AutoSize := False;
      Readout.SetBounds(Control.BoundsRect.Right, 0, 48, RowHeight);
      Readout.AlignWithMargins := True;
      Readout.Margins.SetBounds(4, 0, 0, 0);
      Readout.Layout := tlCenter;
      Readout.Align := alLeft;
    end;
    Group.AutoSize := True;
  end;

  function Slider(const Caption: string; Min, Max: Integer; out Readout: TLabel): THorizontalTrackBarControl;
  begin
    Result := THorizontalTrackBarControl.Create(Self);
    Readout := TLabel.Create(Self);
    AddSetting(Caption, Result, 116, Readout);
    Result.BackgroundColor := ChromeColor;
    Result.FillColor := TColor($00D89458);
    Result.ThumbBorderColor := TextColor;
    Result.ShowTicks := False;
    Result.SetRange(Min, Max);
    Result.WheelChangesPosition := False;
    Result.OnChange := StyleChange;
    Result.OnMouseDown := StyleMouseDown;
    Result.OnMouseUp := StyleMouseUp;
  end;

begin
  inherited CreateNew(nil);
  FOwnerWindow := OwnerWindow;
  FSave := Save;
  FDoc := Document;
  FBackground := Background;
  FPathsDirty := True;
  FBitmap := TBitmap.Create;
  FBitmap.PixelFormat := pf32bit;
  FRenderer := TMarkerRenderer.Create;
  FUndo := TList<TMarkerDocument>.Create;
  FRedo := TList<TMarkerDocument>.Create;
  FStrokeSamples := TList<TPenSample>.Create;
  FSelected := -1;
  FVertex := -1;
  FTool := mtSelect;
  FStyle := DefaultStyle(pkNormal);
  FStyle.Width := EnsureRange(Round(FStyle.Width * FDoc.Width / 1920), 2, 512);
  Caption := '手描きマーカー';
  StyleName := MarkerStyleName;
  Color := ChromeColor;
  Font.PixelsPerInch := PixelsPerInch;
  Font.Name := 'Yu Gothic UI';
  Font.Size := 10;
  Font.Color := TextColor;
  BorderStyle := bsSizeable;
  Position := poDesigned;
  ClientWidth := 970;
  ClientHeight := 660;
  Constraints.MinWidth := 408;
  Constraints.MinHeight := 368;
  KeyPreview := True;
  OnKeyDown := EditorKey;
  OnClose := EditorClose;
  DoubleBuffered := True;

  MainMenu := TMainMenu.Create(Self);
  EditMenu := TMenuItem.Create(MainMenu);
  EditMenu.Caption := '編集(&E)';
  MainMenu.Items.Add(EditMenu);
  FUndoItem := EditItem('元に戻す', Ord('Z'), [ssCtrl], UndoClick);
  FRedoItem := EditItem('やり直す', Ord('Y'), [ssCtrl], RedoClick);
  FDeleteItem := EditItem('削除', VK_DELETE, [], DeleteClick);
  FKindItem := EditItem('頂点の種類', Ord('T'), [ssCtrl], KindClick);
  Menu := MainMenu;

  Settings := TFlowPanel.Create(Self);
  Settings.Parent := Self;
  Settings.Align := alTop;
  Settings.Height := 46;
  Settings.AutoSize := True;
  Settings.BevelOuter := bvNone;
  Settings.ParentBackground := False;
  Settings.StyleElements := Settings.StyleElements - [seClient];
  Settings.Color := ChromeColor;
  Settings.Padding.SetBounds(12, 8, 0, 4);
  FPenPicker := TComboBox.Create(Self);
  AddSetting('ペン先', FPenPicker, 112, nil);
  FPenPicker.Style := csDropDownList;
  for Kind := Low(TPenKind) to High(TPenKind) do FPenPicker.Items.Add(PenNames[Kind]);
  FPenPicker.OnChange := PenChange;
  FSize := Slider('太さ', 1, 512, FSizeValue);
  FOpacity := Slider('不透明度', 0, 100, FOpacityValue);

  Footer := ChromePanel(Self, alBottom);
  Footer.Height := 36;
  Footer.Padding.SetBounds(12, 0, 12, 0);
  FStatus := TLabel.Create(Self);
  FStatus.Parent := Footer;
  FStatus.StyleElements := FStatus.StyleElements - [seFont];
  FStatus.AutoSize := False;
  FStatus.Align := alClient;
  FStatus.Layout := tlCenter;
  FStatus.WordWrap := True;

  Palette := ChromePanel(Self, alLeft);
  Palette.Width := 48;
  ToolButton(mtSelect, '選択');
  ToolButton(mtContinuous, '連続線');
  ToolButton(mtFreehand, '自由線');

  FColorDock := TMarkerColorDock.Create(Self);
  FColorDock.Parent := Self;
  FColorDock.Align := alRight;
  FColorDock.FHue.OnChange := ColorChange;
  FColorDock.FHue.OnMouseDown := StyleMouseDown;
  FColorDock.FHue.OnMouseUp := StyleMouseUp;
  FColorDock.FArea.OnChange := ColorChange;
  FColorDock.FArea.OnMouseDown := StyleMouseDown;
  FColorDock.FArea.OnMouseUp := StyleMouseUp;
  FColorDock.FCode.OnExit := ColorCodeExit;
  FColorDock.FCode.OnKeyDown := ColorCodeKeyDown;

  FView := TMarkerCanvas.Create(Self);
  FView.FEditor := Self;
  FView.ControlStyle := FView.ControlStyle + [csDoubleClicks] - [csCaptureMouse];
  FView.Parent := Self;
  FView.Align := alClient;
  FView.DoubleBuffered := True;
  FView.TabStop := True;
  FView.OnMouseDown := ViewDown;
  FView.OnMouseMove := ViewMove;
  FView.OnMouseUp := ViewUp;
  ActiveControl := FView;
  SyncControls;

  OwnerMonitor := Screen.MonitorFromWindow(FOwnerWindow);
  if OwnerMonitor = nil then OwnerMonitor := Screen.PrimaryMonitor;
  WorkArea := OwnerMonitor.WorkareaRect;
  SetBounds(WorkArea.Left, WorkArea.Top, Width, Height);
  ScaleForPPI(OwnerMonitor.PixelsPerInch);
  W := Min(Width, WorkArea.Width);
  H := Min(Height, WorkArea.Height);
  SetBounds(WorkArea.Left + (WorkArea.Width - W) div 2, WorkArea.Top + (WorkArea.Height - H) div 2, W, H);
end;

destructor TMarkerEditor.Destroy;
begin
  if FView <> nil then FView.FEditor := nil;
  FStrokeSamples.Free;
  FRedo.Free;
  FUndo.Free;
  FRenderer.Free;
  FBitmap.Free;
  inherited;
end;

procedure TMarkerEditor.CreateParams(var Params: TCreateParams);
begin
  inherited;
  if FOwnerWindow <> 0 then Params.WndParent := FOwnerWindow;
end;

procedure TMarkerEditor.SetStatus;
begin
  case FTool of
    mtSelect: FStatus.Caption := '線・頂点・ハンドルをドラッグ　右クリックで頂点の追加・削除';
    mtContinuous: FStatus.Caption := 'クリックで頂点を追加　終点をダブルクリックで確定';
    mtFreehand: FStatus.Caption := 'マウスでドラッグ、またはペンで手描き';
  end;
  if Length(FBackground.Pixels) = 0 then FStatus.Caption := '背景を取得できませんでした。 ' + FStatus.Caption;
end;

procedure TMarkerEditor.SyncControls;
var S: TStrokeStyle;
begin
  FSync := True;
  try
    S := CurrentStyle;
    FPenPicker.ItemIndex := Ord(S.Kind);
    SyncColor(S.RGB);
    FSize.Position := Round(S.Width);
    FSizeValue.Caption := IntToStr(FSize.Position) + ' px';
    FOpacity.Position := S.Opacity;
    FOpacityValue.Caption := IntToStr(FOpacity.Position) + '%';
    FToolButtons[FTool].Down := True;
    FDeleteItem.Enabled := (FTool = mtSelect) and (FSelected >= 0);
    FKindItem.Enabled := FDeleteItem.Enabled and (FVertex >= 0);
    if FKindItem.Enabled then
      if FDoc.Strokes[FSelected].Anchors[FVertex].Kind = akSmooth then
        FKindItem.Caption := '鋭角頂点にする'
      else FKindItem.Caption := 'ベジェ頂点にする'
    else FKindItem.Caption := '頂点の種類';
    FUndoItem.Enabled := (FUndo.Count > 0) or (Length(FPending) > 0);
    FRedoItem.Enabled := (FRedo.Count > 0) and (Length(FPending) = 0);
    SetStatus;
  finally
    FSync := False;
  end;
end;

procedure TMarkerEditor.Changed;
begin
  FPathsDirty := True;
  FRenderValid := False;
  SyncControls;
  FView.Invalidate;
end;

procedure TMarkerEditor.EnsurePaths;
begin
  if not FPathsDirty then Exit;
  FPaths := BuildPaths(FDoc);
  FPathsDirty := False;
end;

procedure TMarkerEditor.PushUndo(const Before: TMarkerDocument);
begin
  if FUndo.Count = 40 then FUndo.Delete(0);
  FUndo.Add(Before);
  FRedo.Clear;
end;

procedure TMarkerEditor.BeginChange;
begin
  PushUndo(FDoc);
  FDoc.Strokes := Copy(FDoc.Strokes);
end;

procedure TMarkerEditor.AddStroke(const Stroke: TMarkerStroke);
var Pixels: TRGBAPixels;
begin
  if Length(FDoc.Strokes) >= MaxMarkerStrokes then Exit;
  if PointCount(FDoc) + Length(Stroke.Anchors) + Length(Stroke.Samples) > MaxMarkerPoints then Exit;
  BeginChange;
  SetLength(FDoc.Strokes, Length(FDoc.Strokes) + 1);
  FDoc.Strokes[High(FDoc.Strokes)] := Stroke;
  FPathsDirty := True;
  if FRenderValid then
  begin
    FRenderValid := False;
    FRenderer.RenderPreview(BuildPath(Stroke, FDoc.Width), (Stroke.Input = ikPen) and FPreviewFreehand);
    Pixels := FRenderer.FinishPreview(True);
    ComposePreview(Pixels, FBitmap.Width, FBitmap.Height);
    FPreviewActive := False;
    FPreviewFreehand := False;
    FRenderValid := True;
  end;
  SyncControls;
  FView.Invalidate;
end;

procedure TMarkerEditor.CurveClick(const P: TPoint);
var NowTicks: UInt64; Radius: Integer; Position: TPointF;
begin
  if not FContent.Contains(P) then
  begin
    FLastCurveClickTime := 0;
    Exit;
  end;
  NowTicks := GetTickCount64;
  Radius := MulDiv(6, FView.CurrentPPI, 96);
  if (FLastCurveClickTime <> 0) and (NowTicks - FLastCurveClickTime <= GetDoubleClickTime)
    and (Sqr(P.X - FLastCurveClick.X) + Sqr(P.Y - FLastCurveClick.Y) <= Sqr(Radius)) then
  begin
    FLastCurveClickTime := 0;
    if Length(FPending) >= 2 then FinishCurve;
    Exit;
  end;
  FLastCurveClick := P;
  FLastCurveClickTime := NowTicks;
  if Length(FPending) >= MaxStrokePoints then Exit;
  Position := ToWorld(P.X, P.Y);
  if (Length(FPending) > 0) and (FPending[High(FPending)].Position = Position) then Exit;
  SetLength(FPending, Length(FPending) + 1);
  FPending[High(FPending)].Position := Position;
  FHovering := False;
  SyncControls;
  FView.Invalidate;
end;

procedure TMarkerEditor.CurveHover(const P: TPoint);
begin
  if Length(FPending) = 0 then Exit;
  FHover := ToWorld(P.X, P.Y);
  FHovering := FContent.Contains(P);
  FView.Invalidate;
end;

procedure TMarkerEditor.FinishCurve;
var Stroke: TMarkerStroke; I: Integer;
begin
  FLastCurveClickTime := 0;
  FHovering := False;
  if Length(FPending) = 0 then Exit;
  Stroke.Style := FStyle;
  Stroke.Input := ikMouse;
  Stroke.Anchors := FPending;
  FPending := nil;
  for I := 0 to High(Stroke.Anchors) do SetAutomaticHandles(Stroke.Anchors, I);
  AddStroke(Stroke);
  SyncControls;
  FView.Invalidate;
end;

procedure TMarkerEditor.SelectTool(Sender: TObject);
var Tool: TMarkerTool;
begin
  Tool := TMarkerTool(TSpeedButton(Sender).Tag);
  if Tool = FTool then Exit;
  FinishCurve;
  FinishFreehand(True);
  FTool := Tool;
  if FTool <> mtSelect then
  begin
    FSelected := -1;
    FVertex := -1;
  end;
  SyncControls;
  FView.Invalidate;
end;

procedure TMarkerEditor.UndoClick(Sender: TObject);
begin
  FStyleGesture := nil;
  EndDrag(False);
  if Length(FPending) > 0 then
  begin
    SetLength(FPending, Length(FPending) - 1);
    FLastCurveClickTime := 0;
    SyncControls;
    FView.Invalidate;
    Exit;
  end;
  if FUndo.Count = 0 then Exit;
  FRedo.Add(FDoc);
  FDoc := FUndo.Last;
  FUndo.Delete(FUndo.Count - 1);
  FSelected := -1;
  FVertex := -1;
  Changed;
end;

procedure TMarkerEditor.RedoClick(Sender: TObject);
begin
  FStyleGesture := nil;
  EndDrag(False);
  if (FRedo.Count = 0) or (Length(FPending) > 0) then Exit;
  FUndo.Add(FDoc);
  FDoc := FRedo.Last;
  FRedo.Delete(FRedo.Count - 1);
  FSelected := -1;
  FVertex := -1;
  Changed;
end;

procedure TMarkerEditor.DeleteClick(Sender: TObject);
var I: Integer; Stroke: ^TMarkerStroke;
begin
  if (FTool <> mtSelect) or (FSelected < 0) then Exit;
  EndDrag(False);
  BeginChange;
  Stroke := @FDoc.Strokes[FSelected];
  if (FVertex >= 0) and (Length(Stroke^.Anchors) > 1) then
  begin
    Stroke^.Anchors := Copy(Stroke^.Anchors);
    for I := FVertex to High(Stroke^.Anchors) - 1 do Stroke^.Anchors[I] := Stroke^.Anchors[I + 1];
    SetLength(Stroke^.Anchors, Length(Stroke^.Anchors) - 1);
  end
  else
  begin
    for I := FSelected to High(FDoc.Strokes) - 1 do FDoc.Strokes[I] := FDoc.Strokes[I + 1];
    SetLength(FDoc.Strokes, Length(FDoc.Strokes) - 1);
    FSelected := -1;
  end;
  FVertex := -1;
  Changed;
end;

procedure TMarkerEditor.KindClick(Sender: TObject);
var Stroke: ^TMarkerStroke; Kind: DrawMarker_Model.TAnchorKind;
begin
  if (FTool <> mtSelect) or (FVertex < 0) then Exit;
  EndDrag(False);
  BeginChange;
  Stroke := @FDoc.Strokes[FSelected];
  Stroke^.Anchors := Copy(Stroke^.Anchors);
  if Stroke^.Anchors[FVertex].Kind = akSmooth then Kind := akCorner else Kind := akSmooth;
  SetAnchorKind(Stroke^.Anchors, FVertex, Kind);
  Changed;
end;

function TMarkerEditor.CanInsertVertex(Segment: Integer; Parameter: Single): Boolean;
begin
  Result := (FSelected >= 0) and (FDoc.Strokes[FSelected].Input = ikMouse) and
    (Segment >= 0) and (Segment < High(FDoc.Strokes[FSelected].Anchors)) and
    (Parameter > 0.001) and (Parameter < 0.999) and
    (Length(FDoc.Strokes[FSelected].Anchors) < MaxStrokePoints) and
    (PointCount(FDoc) < MaxMarkerPoints);
end;

function TMarkerEditor.InsertVertex(Segment: Integer; Parameter: Single): Boolean;
begin
  Result := CanInsertVertex(Segment, Parameter);
  if not Result then Exit;
  BeginChange;
  FDoc.Strokes[FSelected].Anchors := Copy(FDoc.Strokes[FSelected].Anchors);
  SplitCurve(FDoc.Strokes[FSelected].Anchors, Segment, Parameter);
  FVertex := Segment + 1;
  Changed;
end;

procedure TMarkerEditor.ShowSelectionMenu(const Position: TPoint; Segment: Integer; Parameter: Single);
const
  DeleteCommand = 1;
  InsertCommand = 2;
  KindCommand = 3;
var Popup: HMENU; ScreenPosition: TPoint;
begin
  Popup := CreatePopupMenu;
  if Popup = 0 then Exit;
  try
    AppendMenu(Popup, MF_STRING, DeleteCommand, '削除');
    if FVertex >= 0 then
      AppendMenu(Popup, MF_STRING, KindCommand, PChar(FKindItem.Caption))
    else if CanInsertVertex(Segment, Parameter) then
      AppendMenu(Popup, MF_STRING, InsertCommand, '頂点を追加');
    ScreenPosition := FView.ClientToScreen(Position);
    case Integer(TrackPopupMenu(Popup, TPM_RIGHTBUTTON or TPM_RETURNCMD or TPM_NONOTIFY,
      ScreenPosition.X, ScreenPosition.Y, 0, FView.Handle, nil)) of
      DeleteCommand: DeleteClick(nil);
      InsertCommand: InsertVertex(Segment, Parameter);
      KindCommand: KindClick(nil);
    end;
  finally
    DestroyMenu(Popup);
  end;
end;

function TMarkerEditor.CurrentStyle: TStrokeStyle;
begin
  if (FTool = mtSelect) and (FSelected >= 0) then Exit(FDoc.Strokes[FSelected].Style);
  Result := FStyle;
end;

procedure TMarkerEditor.ApplyStyle(Sender: TObject);
var S: TStrokeStyle;
begin
  if (FTool = mtSelect) and (FSelected >= 0) then
  begin
    S := FDoc.Strokes[FSelected].Style;
    if (S.Kind = FStyle.Kind) and (S.RGB = FStyle.RGB) and (S.Width = FStyle.Width) and
      (S.Opacity = FStyle.Opacity) then Exit;
    if (FStyleGesture = Sender) and (GetCaptureControl = FStyleGesture) then
    begin
      if not FRecordedStyleGesture then
      begin
        BeginChange;
        FRecordedStyleGesture := True;
      end;
    end
    else BeginChange;
    FDoc.Strokes[FSelected].Style := FStyle;
  end;
  Changed;
end;

procedure TMarkerEditor.StyleMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbLeft then Exit;
  if ((Sender = FColorDock.FArea) or (Sender = FColorDock.FHue)) and (ActiveControl = FColorDock.FCode) then
    FView.SetFocus;
  FStyleGesture := TControl(Sender);
  FRecordedStyleGesture := False;
end;

procedure TMarkerEditor.StyleMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if (Button = mbLeft) and (Sender = FStyleGesture) then FStyleGesture := nil;
end;

procedure TMarkerEditor.PenChange(Sender: TObject);
begin
  if FSync or (FPenPicker.ItemIndex < 0) then Exit;
  FStyle := DefaultStyle(TPenKind(FPenPicker.ItemIndex));
  FStyle.Width := EnsureRange(Round(FStyle.Width * FDoc.Width / 1920), 2, 512);
  ApplyStyle(Sender);
end;

procedure TMarkerEditor.StyleChange(Sender: TObject);
begin
  if FSync then Exit;
  FStyle := CurrentStyle;
  if Sender = FSize then FStyle.Width := FSize.Position
  else FStyle.Opacity := FOpacity.Position;
  ApplyStyle(Sender);
end;

procedure TMarkerEditor.SyncColor(Color: Cardinal);
var Sample: TColor; Hue, Saturation, Value: Double;
begin
  Sample := RGB(Color shr 16, (Color shr 8) and 255, Color and 255);
  if FColorDock.FArea.Color <> Sample then
  begin
    ColorToHsv(Sample, Hue, Saturation, Value);
    if Saturation > 0 then FColorDock.FHue.Color := HsvToColor(Hue, 1, 1);
    FColorDock.FArea.BaseColor := FColorDock.FHue.Color;
    FColorDock.FArea.Color := Sample;
  end;
  FColorDock.FSample.Brush.Color := Sample;
  FColorDock.FCode.Text := '#' + IntToHex(Color, 6);
end;

procedure TMarkerEditor.ColorChange(Sender: TObject);
var Saturation, Value: Double; Sample: Cardinal;
begin
  if FSync then Exit;
  if Sender = FColorDock.FHue then
  begin
    ColorToSv(FColorDock.FArea.Color, Saturation, Value);
    FColorDock.FArea.BaseColor := FColorDock.FHue.Color;
    FColorDock.FArea.Color := HsvToColor(ColorHue(FColorDock.FHue.Color), Saturation, Value);
  end;
  Sample := ColorToRGB(FColorDock.FArea.Color);
  FStyle := CurrentStyle;
  FStyle.RGB := (Cardinal(GetRValue(Sample)) shl 16) or
    (Cardinal(GetGValue(Sample)) shl 8) or GetBValue(Sample);
  ApplyStyle(Sender);
end;

procedure TMarkerEditor.ColorCodeExit(Sender: TObject);
var Sample: TColor;
begin
  if FSync then Exit;
  if TryParseColorCode(FColorDock.FCode.Text, Sample) then
  begin
    FStyle := CurrentStyle;
    FStyle.RGB := (Cardinal(GetRValue(Sample)) shl 16) or
      (Cardinal(GetGValue(Sample)) shl 8) or GetBValue(Sample);
    ApplyStyle(Sender);
  end;
  SyncColor(CurrentStyle.RGB);
end;

procedure TMarkerEditor.ColorCodeKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_RETURN: ColorCodeExit(Sender);
    VK_ESCAPE: SyncColor(CurrentStyle.RGB);
  else
    Exit;
  end;
  Key := 0;
end;

procedure TMarkerEditor.EditorClose(Sender: TObject; var Action: TCloseAction);
begin
  try
    if ActiveControl = FColorDock.FCode then ColorCodeExit(FColorDock.FCode);
    EndDrag(False);
    FinishFreehand(False);
    FinishCurve;
    if not FSave(WriteDocument(FDoc)) then Action := caNone;
  except
    on E: Exception do
    begin
      Action := caNone;
      MessageDlg(E.Message, mtError, [mbOK], 0);
    end;
  end;
end;

function TMarkerEditor.IsShortCut(var Message: TWMKey): Boolean;
begin
  // 数値欄にフォーカスがある場合は文字の削除を優先する。
  if (Message.CharCode = VK_DELETE) and (ActiveControl <> FView) then Exit(False);
  Result := inherited IsShortCut(Message);
end;

procedure TMarkerEditor.EditorKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (ActiveControl = FColorDock.FCode) and (Key in [VK_RETURN, VK_ESCAPE]) then Exit;
  if (Shift = [ssCtrl, ssShift]) and (Key = Ord('Z')) then RedoClick(nil)
  else if (Key = VK_RETURN) and (Length(FPending) > 0) then FinishCurve
  else if (Key = VK_ESCAPE) and (FDragging <> dpNone) then EndDrag(True)
  else if (Key = VK_ESCAPE) and (FMouseDrawing or (FPenID <> 0)) then FinishFreehand(True)
  else if (Key = VK_ESCAPE) and (Length(FPending) > 0) then
  begin
    FPending := nil;
    FLastCurveClickTime := 0;
    FHovering := False;
    SyncControls;
    FView.Invalidate;
  end
  else Exit;
  Key := 0;
end;

function TMarkerEditor.ToWorld(X, Y: Integer): TPointF;
begin
  Result := PointF((X - FContent.Left) * FDoc.Width / Max(1, FContent.Width),
    (Y - FContent.Top) * FDoc.Height / Max(1, FContent.Height));
end;

function TMarkerEditor.ToView(const P: TPointF): TPoint;
begin
  Result := Point(FContent.Left + Round(P.X * FContent.Width / FDoc.Width),
    FContent.Top + Round(P.Y * FContent.Height / FDoc.Height));
end;

function TMarkerEditor.HitSelectedPoint(X, Y: Integer; IncludeHandles: Boolean;
  out Index: Integer): TDragPart;
var A: TCurveAnchor; P: TPoint; I, Radius: Integer;
  function Near(const Pos: TPointF): Boolean;
  begin
    P := ToView(Pos);
    Result := (Abs(P.X - X) <= Radius) and (Abs(P.Y - Y) <= Radius);
  end;
begin
  Result := dpNone;
  Index := -1;
  if FSelected < 0 then Exit;
  Radius := MulDiv(7, FView.CurrentPPI, 96);
  for I := 0 to High(FDoc.Strokes[FSelected].Anchors) do
    if Near(FDoc.Strokes[FSelected].Anchors[I].Position) then
    begin
      Index := I;
      Exit(dpVertex);
    end;
  if not IncludeHandles or (FVertex < 0) then Exit;
  A := FDoc.Strokes[FSelected].Anchors[FVertex];
  Index := FVertex;
  if (FVertex > 0) and Near(A.Position + A.InHandle) then Exit(dpIncoming);
  if (FVertex < High(FDoc.Strokes[FSelected].Anchors)) and Near(A.Position + A.OutHandle) then Exit(dpOutgoing);
  Index := -1;
end;

procedure TMarkerEditor.ViewDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var P: TPointF; I, Segment, Hit, HitSegment, Index: Integer; T, HitT, Limit: Single;
  InsertWithClick: Boolean;
begin
  if (FTool <> mtSelect) and (PromotedMouse or (FPenID <> 0)) then Exit;
  FView.SetFocus;
  if FTool = mtContinuous then
  begin
    if Button = mbLeft then CurveClick(Point(X, Y)) else FLastCurveClickTime := 0;
    Exit;
  end;
  if not FContent.Contains(Point(X, Y)) then Exit;
  if FTool = mtFreehand then
  begin
    if (Button = mbLeft) and not FMouseDrawing then
    begin
      SetCapture(FView.Handle);
      FMouseDrawing := True;
      FStrokeStart := GetTickCount;
      AddFreehandSample(Point(X, Y), FStrokeStart, 1);
      FView.Invalidate;
    end;
    Exit;
  end;
  if not (Button in [mbLeft, mbRight]) then Exit;
  P := ToWorld(X, Y);
  EndDrag(False);
  InsertWithClick := (Button = mbLeft) and (ssCtrl in Shift);
  HitSegment := -1;
  HitT := 0;
  if not InsertWithClick then FDragging := HitSelectedPoint(X, Y, Button = mbLeft, Index);
  if FDragging <> dpNone then FVertex := Index
  else
  begin
    EnsurePaths;
    Hit := -1;
    for I := High(FPaths) downto 0 do
    begin
      Limit := Max(MulDiv(8, FView.CurrentPPI, 96), FPaths[I].Style.Width *
        Min(FContent.Width / FDoc.Width, FContent.Height / FDoc.Height) / 2 +
        MulDiv(4, FView.CurrentPPI, 96));
      if HitPath(FPaths[I], P, FContent.Width / FDoc.Width,
        FContent.Height / FDoc.Height, Limit, Segment, T) then
      begin
        Hit := I;
        HitSegment := Segment;
        HitT := T;
        Break;
      end;
    end;
    FSelected := Hit;
    FVertex := -1;
    if Hit >= 0 then
    begin
      if InsertWithClick then
        if InsertVertex(HitSegment, HitT) then Exit;
      if not InsertWithClick then FDragging := HitSelectedPoint(X, Y, False, FVertex);
      if FDragging = dpNone then FDragging := dpStroke;
    end;
  end;
  SyncControls;
  FView.Invalidate;
  if (Button = mbRight) and (FSelected >= 0) then
  begin
    FDragging := dpNone;
    ShowSelectionMenu(Point(X, Y), HitSegment, HitT);
  end
  else if (Button = mbLeft) and (FDragging <> dpNone) then
  begin
    FBeforeDrag := FDoc;
    FDragOrigin := P;
    FDragChanged := False;
    SetCapture(FView.Handle);
  end;
end;

procedure TMarkerEditor.ViewMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var P, Offset: TPointF; Stroke: ^TMarkerStroke; Original: TMarkerStroke; I: Integer;
begin
  if FTool <> mtSelect then
  begin
    if PromotedMouse then Exit;
    if FTool = mtContinuous then CurveHover(Point(X, Y))
    else if FMouseDrawing then
    begin
      AddFreehandSample(Point(X, Y), GetTickCount, 1);
      FView.Invalidate;
    end;
    Exit;
  end;
  if (FDragging = dpNone) or (GetCapture <> FView.Handle) then Exit;
  P := ToWorld(X, Y);
  Offset := P - FDragOrigin;
  if not FDragChanged then
  begin
    if Magnitude(Offset) < 0.25 then Exit;
    FDoc.Strokes := Copy(FDoc.Strokes);
    FDoc.Strokes[FSelected].Anchors := Copy(FDoc.Strokes[FSelected].Anchors);
    FDoc.Strokes[FSelected].Samples := Copy(FDoc.Strokes[FSelected].Samples);
    FDragChanged := True;
  end;
  Stroke := @FDoc.Strokes[FSelected];
  Original := FBeforeDrag.Strokes[FSelected];
  case FDragging of
    dpStroke:
      begin
        for I := 0 to High(Stroke^.Anchors) do
          Stroke^.Anchors[I].Position := Original.Anchors[I].Position + Offset;
        for I := 0 to High(Stroke^.Samples) do
          Stroke^.Samples[I].Position := Original.Samples[I].Position + Offset;
      end;
    dpVertex: Stroke^.Anchors[FVertex].Position := Original.Anchors[FVertex].Position + Offset;
    dpIncoming: MoveHandle(Stroke^.Anchors[FVertex], True, P);
    dpOutgoing: MoveHandle(Stroke^.Anchors[FVertex], False, P);
  end;
  FPathsDirty := True;
  FRenderValid := False;
  FView.Invalidate;
end;

procedure TMarkerEditor.ViewUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if (Button = mbLeft) and FMouseDrawing and not PromotedMouse then
  begin
    AddFreehandSample(Point(X, Y), GetTickCount, 1);
    FinishFreehand(False);
  end;
end;

procedure TMarkerEditor.EndDrag(Cancel: Boolean);
begin
  if FDragging = dpNone then Exit;
  FDragging := dpNone;
  if GetCapture = FView.Handle then ReleaseCapture;
  if FDragChanged then
  begin
    if Cancel then FDoc := FBeforeDrag else PushUndo(FBeforeDrag);
    FDragChanged := False;
    Changed;
  end;
  FBeforeDrag := Default(TMarkerDocument);
end;

procedure TMarkerEditor.AddFreehandSample(const P: TPoint; Timestamp: Cardinal; Pressure: Single);
var Sample, Previous: TPenSample; Elapsed: UInt64;
begin
  if FStrokeSamples.Count >= MaxStrokePoints then Exit;
  Elapsed := (UInt64(Timestamp) + UInt64($100000000) - FStrokeStart) and UInt64($FFFFFFFF);
  if Elapsed > 86400000 then Exit;
  Sample.Position := ToWorld(P.X, P.Y);
  Sample.Milliseconds := Integer(Elapsed);
  Sample.Pressure := Pressure;
  if FStrokeSamples.Count > 0 then
  begin
    Previous := FStrokeSamples.Last;
    if Sample.Milliseconds < Previous.Milliseconds then Exit;
    if (Sample.Milliseconds = Previous.Milliseconds) and (Sample.Position = Previous.Position)
      and (Sample.Pressure = Previous.Pressure) then Exit;
  end;
  FStrokeSamples.Add(Sample);
end;

procedure TMarkerEditor.FinishFreehand(Cancel: Boolean);
var Stroke: TMarkerStroke; MouseDrawing: Boolean;
begin
  if not FMouseDrawing and (FPenID = 0) then Exit;
  MouseDrawing := FMouseDrawing;
  FMouseDrawing := False;
  FPenID := 0;
  if MouseDrawing and (GetCapture = FView.Handle) then ReleaseCapture;
  if not Cancel and (FStrokeSamples.Count > 0) then
  begin
    Stroke.Input := ikPen; // 既存のサンプル形式をマウスとペンで共有する。
    Stroke.Style := FStyle;
    Stroke.Samples := FStrokeSamples.ToArray;
    FStrokeSamples.Clear;
    AddStroke(Stroke);
  end
  else FStrokeSamples.Clear;
  FPreviewFreehand := False;
  FView.Invalidate;
end;

procedure TMarkerEditor.AddPenHistory(ID: Cardinal; const Pen: POINTER_PEN_INFO;
  IncludeHistory: Boolean);
var History: TArray<POINTER_PEN_INFO>; Count: Cardinal; I: Integer;
  procedure Append(const Info: POINTER_PEN_INFO);
  var Pressure: Single;
  begin
    Pressure := 1;
    if (Info.penMask and PEN_MASK_PRESSURE) <> 0 then
      Pressure := Min(1.0, Info.pressure / 1024);
    AddFreehandSample(FView.ScreenToClient(Info.pointerInfo.ptPixelLocation),
      Info.pointerInfo.dwTime, Pressure);
  end;
begin
  Count := Pen.pointerInfo.historyCount;
  if IncludeHistory and (Count > 1) and (Count <= 512) then
  begin
    SetLength(History, Count);
    if GetPointerPenInfoHistory(ID, @Count, @History[0]) then
    begin
      for I := Integer(Count) - 1 downto 0 do Append(History[I]);
      Exit;
    end;
  end;
  Append(Pen);
end;

function TMarkerEditor.HandlePointer(const Msg: TMessage): Boolean;
var ID: Cardinal; Pen: POINTER_PEN_INFO; P: TPoint;
begin
  Result := False;
  if FTool = mtSelect then Exit;
  ID := LoWord(Msg.WParam);
  if Msg.Msg = WM_POINTERCAPTURECHANGED then
  begin
    if (FPenID <> 0) and (ID = FPenID) then
    begin
      FinishFreehand(True);
      Result := True;
    end;
    Exit;
  end;
  if not GetPointerPenInfo(ID, @Pen) then Exit;
  Result := True;
  P := FView.ScreenToClient(Pen.pointerInfo.ptPixelLocation);
  if FTool = mtContinuous then
  begin
    case Msg.Msg of
      WM_POINTERDOWN:
        begin
          FView.SetFocus;
          CurveClick(P);
        end;
      WM_POINTERUPDATE: CurveHover(P);
    end;
    Exit;
  end;
  if Msg.Msg = WM_POINTERDOWN then
  begin
    if (FPenID <> 0) or FMouseDrawing or not FContent.Contains(P) then Exit;
    FView.SetFocus;
    FPenID := ID;
    FStrokeStart := Pen.pointerInfo.dwTime;
  end;
  if ID <> FPenID then Exit;
  AddPenHistory(ID, Pen, Msg.Msg <> WM_POINTERDOWN);
  if Msg.Msg = WM_POINTERUP then FinishFreehand(False) else FView.Invalidate;
end;

procedure TMarkerEditor.DrawSelection;
var
  A: TCurveAnchor;
  P, H: TPoint;
  I, HandleRadius, VertexRadius: Integer;
  Path: TMarkerPath;
  C: TCanvas;
  procedure Handle(const Offset: TPointF);
  begin
    H := ToView(A.Position + Offset);
    C.MoveTo(P.X, P.Y);
    C.LineTo(H.X, H.Y);
    C.Ellipse(H.X - HandleRadius, H.Y - HandleRadius,
      H.X + HandleRadius + 1, H.Y + HandleRadius + 1);
  end;
begin
  if (FTool <> mtSelect) or (FSelected < 0) then Exit;
  HandleRadius := MulDiv(4, FView.CurrentPPI, 96);
  VertexRadius := MulDiv(5, FView.CurrentPPI, 96);
  C := FView.Canvas;
  C.Pen.Color := clWhite;
  C.Pen.Style := psDot;
  Path := FPaths[FSelected];
  for I := 0 to High(Path.Points) do
  begin
    P := ToView(Path.Points[I].Position);
    if I = 0 then C.MoveTo(P.X, P.Y) else C.LineTo(P.X, P.Y);
  end;
  C.Pen.Style := psSolid;
  for I := 0 to High(FDoc.Strokes[FSelected].Anchors) do
  begin
    A := FDoc.Strokes[FSelected].Anchors[I];
    P := ToView(A.Position);
    C.Pen.Color := $003B3027;
    C.Brush.Color := clWhite;
    if I = FVertex then
    begin
      C.Pen.Color := $00F5BC5C;
      C.Brush.Color := $00F5BC5C;
      if I > 0 then Handle(A.InHandle);
      if I < High(FDoc.Strokes[FSelected].Anchors) then Handle(A.OutHandle);
    end;
    if A.Kind = akSmooth then
      C.Ellipse(P.X - VertexRadius, P.Y - VertexRadius, P.X + VertexRadius + 1, P.Y + VertexRadius + 1)
    else
      C.Rectangle(P.X - VertexRadius, P.Y - VertexRadius, P.X + VertexRadius + 1, P.Y + VertexRadius + 1);
  end;
end;

procedure TMarkerEditor.ComposePreview(const Markers: TRGBAPixels; Width, Height: Integer);
var
  X, Y, I, J, K, Alpha, BackgroundAlpha, Base: Integer;
  Fore, Back: TPIXEL_RGBA;
  Line: PCardinal;
  R, G, B: Integer;
begin
  if (Width <> FBitmap.Width) or (Height <> FBitmap.Height) then FBitmap.SetSize(Width, Height);
  I := 0;
  for Y := 0 to Height - 1 do
  begin
    // VCL は DIB の向きを補正し、ScanLine[0] を表示上の先頭行として返す。
    Line := FBitmap.ScanLine[Y];
    J := (Y * FBackground.Height div Height) * FBackground.Width;
    for X := 0 to Width - 1 do
    begin
      Base := 47 + ((X div 16 + Y div 16) and 1) * 18;
      Back := Default(TPIXEL_RGBA);
      if Length(FBackground.Pixels) > 0 then
      begin
        K := J + X * FBackground.Width div Width;
        Back := FBackground.Pixels[K];
      end;
      Fore := Markers[I];
      Inc(I);
      Alpha := Fore.A;
      BackgroundAlpha := (Back.A * (255 - Alpha) + 127) div 255;
      Base := Base * (255 - Alpha - BackgroundAlpha);
      R := (Fore.R * Alpha + Back.R * BackgroundAlpha + Base + 127) div 255;
      G := (Fore.G * Alpha + Back.G * BackgroundAlpha + Base + 127) div 255;
      B := (Fore.B * Alpha + Back.B * BackgroundAlpha + Base + 127) div 255;
      Line^ := (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
      Inc(Line);
    end;
  end;
end;

procedure TMarkerEditor.DrawView;
var
  W, H, FitWidth, FitHeight, I, Margin: Integer;
  Scale: Double;
  Temp: TMarkerStroke;
  Pixels: TRGBAPixels;
  Preview: Boolean;
begin
  FView.Canvas.Brush.Color := CanvasColor;
  FView.Canvas.FillRect(FView.ClientRect);
  Margin := MulDiv(12, FView.CurrentPPI, 96);
  if (FView.Width <= 2 * Margin) or (FView.Height <= 2 * Margin) then
  begin
    FContent := TRect.Empty;
    Exit;
  end;
  FitWidth := FDoc.Width;
  FitHeight := FDoc.Height;
  if Length(FBackground.Pixels) > 0 then
  begin
    FitWidth := FBackground.Width;
    FitHeight := FBackground.Height;
  end;
  Scale := Min((FView.Width - 2 * Margin) / FitWidth, (FView.Height - 2 * Margin) / FitHeight);
  W := Max(1, Round(FitWidth * Scale));
  H := Max(1, Round(FitHeight * Scale));
  FContent := Rect((FView.Width - W) div 2, (FView.Height - H) div 2,
    (FView.Width - W) div 2 + W, (FView.Height - H) div 2 + H);
  Preview := (Length(FPending) > 0) or (FStrokeSamples.Count > 0);
  if not FRenderValid or (W <> FBitmap.Width) or (H <> FBitmap.Height) then
  begin
    EnsurePaths;
    Pixels := FRenderer.Render(FPaths, FDoc.Width, FDoc.Height, W, H, 1E20);
    FRenderValid := Length(Pixels) > 0;
    if not FRenderValid then Exit;
  end
  else if FPreviewActive and not Preview then Pixels := FRenderer.FinishPreview(False);
  if Preview then
  begin
    Temp.Style := FStyle;
    if FStrokeSamples.Count > 0 then
    begin
      Temp.Input := ikPen;
      Temp.Samples := FStrokeSamples.ToArray;
    end
    else
    begin
      Temp.Input := ikMouse;
      Temp.Anchors := Copy(FPending);
      if FHovering and (FHover <> FPending[High(FPending)].Position) then
      begin
        SetLength(Temp.Anchors, Length(Temp.Anchors) + 1);
        Temp.Anchors[High(Temp.Anchors)].Position := FHover;
      end;
      for I := 0 to High(Temp.Anchors) do SetAutomaticHandles(Temp.Anchors, I);
    end;
    Pixels := FRenderer.RenderPreview(BuildPath(Temp, FDoc.Width),
      FPreviewFreehand and (FStrokeSamples.Count > 0));
  end;
  FPreviewActive := Preview;
  FPreviewFreehand := FStrokeSamples.Count > 0;
  if Length(Pixels) > 0 then ComposePreview(Pixels, W, H);
  FView.Canvas.Draw(FContent.Left, FContent.Top, FBitmap);
  DrawSelection;
end;

procedure OpenMarkerEditor(OwnerWindow: HWND; const Document: TMarkerDocument;
  const Background: TMarkerCapture; Save: TMarkerSave);
var
  Editor: TMarkerEditor;
  PreviousStyle: string;
  PreviousDefaultStyle, PreviousShowHint: Boolean;
begin
  PreviousStyle := TStyleManager.ActiveStyle.Name;
  PreviousDefaultStyle := TStyleManager.UseSystemStyleAsDefault;
  PreviousShowHint := Application.ShowHint;
  try
    TStyleManager.UseSystemStyleAsDefault := True;
    TStyleManager.SetStyle(MarkerStyleName);
    Application.ShowHint := True;
    Editor := TMarkerEditor.CreateEditor(OwnerWindow, Document, Background, Save);
    try
      Editor.ShowModal;
    finally
      Editor.Free;
    end;
  finally
    Application.ShowHint := PreviousShowHint;
    TStyleManager.SetStyle(PreviousStyle);
    TStyleManager.UseSystemStyleAsDefault := PreviousDefaultStyle;
  end;
end;

end.
