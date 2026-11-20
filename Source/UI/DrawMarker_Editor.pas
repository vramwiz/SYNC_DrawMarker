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
  ToolbarHeight = 46;

type
  TMarkerEditor = class;
  TMarkerCanvas = class(TCustomControl)
  private
    FEditor: TMarkerEditor;
  protected
    procedure Paint; override;
    procedure WndProc(var Message: TMessage); override;
  end;

  TDragPart = (dpNone, dpStroke, dpVertex, dpIncoming, dpOutgoing, dpMarquee);
  TMarkerTool = (mtSelect, mtContinuous, mtFreehand);
  TStyleField = (sfPen, sfWidth, sfTransparency, sfTip, sfRotation, sfColor);
  TChromePanelClass = class of TPanel;

  TMarkerToolButton = class(TSpeedButton)
  private
    procedure RefreshGlyph(PPI: Integer);
  protected
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
  end;

  TMarkerToolbar = class(TPanel)
  private type
    TSetting = record
      Title, Readout: TLabel;
      Control: TControl;
      MinWidth, PreferredWidth: Integer;
    end;
  private
    FSettings: array[0..3] of TSetting;
    FCount: Integer;
    FArranging: Boolean;
  protected
    procedure AlignControls(AControl: TControl; var Rect: TRect); override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
  public
    procedure AddSetting(const Caption: string; Control: TControl; MinWidth, PreferredWidth: Integer;
      Readout: TLabel = nil);
  end;

  TMarkerColorDock = class(TPanel)
  private
    FTitle, FTransparencyTitle, FTransparencyValue: TLabel;
    FHue: TColorPickerHueBar;
    FArea: TColorPickerSVArea;
    FSample: TShape;
    FCode: TEdit;
    FTransparency: THorizontalTrackBarControl;
  protected
    procedure AlignControls(AControl: TControl; var Rect: TRect); override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

  TMarkerEditor = class(TForm)
  private
    FOwnerWindow: HWND;
    FClosingJSON: string;
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
    FSelectedStrokes: TArray<Integer>;
    FDragging: TDragPart;
    FMarqueeStart, FMarqueeEnd: TPoint;
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
    FPenPicker, FTipPicker: TComboBox;
    FSize, FRotation: THorizontalTrackBarControl;
    FSizeValue, FRotationValue: TLabel;
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
    procedure SetSelection(const Indices: TArray<Integer>);
    function MarqueeBounds: TRect;
    procedure SelectInRect(const Bounds: TRect);
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
    procedure ApplyStyle(Sender: TObject; Field: TStyleField; const Value: TStrokeStyle);
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
      const Background: TMarkerCapture);
    destructor Destroy; override;
    function IsShortCut(var Message: TWMKey): Boolean; override;
    procedure MouseWheelHandler(var Message: TMessage); override;
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
      WM_LBUTTONUP:
        begin
          if FEditor.FDragging = dpMarquee then
            FEditor.FMarqueeEnd := SmallPointToPoint(TWMMouse(Message).Pos);
          FEditor.EndDrag(False);
        end;
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

procedure TMarkerToolbar.AddSetting(const Caption: string; Control: TControl;
  MinWidth, PreferredWidth: Integer; Readout: TLabel);
var Title: TLabel;
begin
  Title := TLabel.Create(Self);
  Title.Parent := Self;
  Title.Caption := Caption;
  Title.StyleElements := Title.StyleElements - [seFont];
  Control.Parent := Self;
  Control.Hint := Caption;
  Control.ShowHint := True;
  if Readout <> nil then
  begin
    Readout.Parent := Self;
    Readout.StyleElements := Readout.StyleElements - [seFont];
    Readout.AutoSize := False;
    Readout.Layout := tlCenter;
  end;
  FSettings[FCount].Title := Title;
  FSettings[FCount].Control := Control;
  FSettings[FCount].Readout := Readout;
  FSettings[FCount].MinWidth := MinWidth;
  FSettings[FCount].PreferredWidth := PreferredWidth;
  Inc(FCount);
  Realign;
end;

procedure TMarkerToolbar.AlignControls(AControl: TControl; var Rect: TRect);
var
  I, X, Inset, Gap, LabelGap, ValueWidth, BaseWidth, FlexWidth, Extra, Width, Height: Integer;
  Compact: Boolean;
  Setting: TSetting;
begin
  if FArranging or (csDestroying in ComponentState) then Exit;
  FArranging := True;
  try
    inherited;
    Compact := ClientWidth < ScaleValue(555);
    if Compact then
    begin
      Inset := ScaleValue(6);
      Gap := ScaleValue(6);
      LabelGap := ScaleValue(4);
      ValueWidth := ScaleValue(42);
    end
    else
    begin
      Inset := ScaleValue(12);
      Gap := ScaleValue(12);
      LabelGap := ScaleValue(8);
      ValueWidth := ScaleValue(48);
    end;
    BaseWidth := 2 * Inset + Max(0, FCount - 1) * Gap;
    FlexWidth := 0;
    for I := 0 to FCount - 1 do
    begin
      Setting := FSettings[I];
      Setting.Title.Visible := not Compact or (Setting.Readout <> nil);
      Inc(BaseWidth, ScaleValue(Setting.MinWidth));
      Inc(FlexWidth, ScaleValue(Setting.PreferredWidth) - ScaleValue(Setting.MinWidth));
      if Setting.Title.Visible then Inc(BaseWidth, Setting.Title.Width + LabelGap);
      if Setting.Readout <> nil then Inc(BaseWidth, ScaleValue(4) + ValueWidth);
    end;
    Extra := EnsureRange(ClientWidth - BaseWidth, 0, FlexWidth);
    X := Inset;
    for I := 0 to FCount - 1 do
    begin
      Setting := FSettings[I];
      if Setting.Title.Visible then
      begin
        Setting.Title.SetBounds(X, (ClientHeight - Setting.Title.Height) div 2,
          Setting.Title.Width, Setting.Title.Height);
        Inc(X, Setting.Title.Width + LabelGap);
      end;
      Width := ScaleValue(Setting.MinWidth);
      if FlexWidth > 0 then
        Inc(Width, Extra * (ScaleValue(Setting.PreferredWidth) - Width) div FlexWidth);
      Height := ScaleValue(32);
      if Setting.Control is TComboBox then Height := Setting.Control.Height;
      Setting.Control.SetBounds(X, (ClientHeight - Height) div 2, Width, Height);
      Inc(X, Width);
      if Setting.Readout <> nil then
      begin
        Inc(X, ScaleValue(4));
        Setting.Readout.SetBounds(X, 0, ValueWidth, ClientHeight);
        Inc(X, ValueWidth);
      end;
      Inc(X, Gap);
    end;
  finally
    FArranging := False;
  end;
end;

procedure TMarkerToolbar.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited;
  if isDpiChange then Height := MulDiv(ToolbarHeight, M, 96);
end;

function CreateMarkerSlider(Owner: TComponent; Min, Max: Integer): THorizontalTrackBarControl;
begin
  Result := THorizontalTrackBarControl.Create(Owner);
  Result.BackgroundColor := ChromeColor;
  Result.FillColor := TColor($00D89458);
  Result.ThumbBorderColor := TextColor;
  Result.ShowTicks := False;
  Result.SetRange(Min, Max);
  Result.WheelChangesPosition := True;
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
  FTransparencyTitle := TLabel.Create(Self);
  FTransparencyTitle.Parent := Self;
  FTransparencyTitle.Caption := '透明度';
  FTransparencyTitle.StyleElements := FTransparencyTitle.StyleElements - [seFont];
  FTransparencyValue := TLabel.Create(Self);
  FTransparencyValue.Parent := Self;
  FTransparencyValue.AutoSize := False;
  FTransparencyValue.Alignment := taRightJustify;
  FTransparencyValue.Layout := tlCenter;
  FTransparencyValue.StyleElements := FTransparencyValue.StyleElements - [seFont];
  FTransparency := CreateMarkerSlider(Self, 0, 100);
  FTransparency.Name := 'TransparencySlider';
  FTransparency.Parent := Self;
end;

procedure TMarkerColorDock.AlignControls(AControl: TControl; var Rect: TRect);
var
  Inset, Gap, HueWidth, CodeHeight, PickerTop, CodeTop, AvailableWidth, Side: Integer;
  TransparencyTop, LabelHeight, SliderHeight, ValueWidth: Integer;
begin
  inherited;
  if (FTransparency = nil) or (csDestroying in ComponentState) then Exit;
  Inset := ScaleValue(12);
  Gap := ScaleValue(8);
  HueWidth := ScaleValue(16);
  CodeHeight := ScaleValue(28);
  LabelHeight := Max(ScaleValue(20), FTransparencyTitle.Height);
  SliderHeight := ScaleValue(28);
  ValueWidth := ScaleValue(44);
  AvailableWidth := ClientWidth - 2 * Inset;
  FTitle.Left := Inset;
  FTitle.Top := Gap;
  PickerTop := FTitle.Top + FTitle.Height + Gap;
  Side := Max(1, Min(AvailableWidth - HueWidth - Gap,
    ClientHeight - PickerTop - CodeHeight - LabelHeight - SliderHeight - 4 * Gap));
  FArea.SetBounds(Inset, PickerTop, Side, Side);
  FHue.SetBounds(Inset + Side + Gap, PickerTop, HueWidth, Side);
  CodeTop := PickerTop + Side + Gap;
  FSample.SetBounds(Inset, CodeTop, CodeHeight, CodeHeight);
  FCode.SetBounds(Inset + CodeHeight + Gap, CodeTop,
    Max(1, AvailableWidth - CodeHeight - Gap), CodeHeight);
  TransparencyTop := CodeTop + CodeHeight + 2 * Gap;
  FTransparencyTitle.SetBounds(Inset, TransparencyTop + (LabelHeight - FTransparencyTitle.Height) div 2,
    FTransparencyTitle.Width, FTransparencyTitle.Height);
  FTransparencyValue.SetBounds(ClientWidth - Inset - ValueWidth, TransparencyTop, ValueWidth, LabelHeight);
  FTransparency.SetBounds(Inset, TransparencyTop + LabelHeight, AvailableWidth, SliderHeight);
end;

constructor TMarkerEditor.CreateEditor(OwnerWindow: HWND; const Document: TMarkerDocument;
  const Background: TMarkerCapture);
var
  Palette, Footer: TPanel;
  Settings: TMarkerToolbar;
  MainMenu: TMainMenu;
  EditMenu: TMenuItem;
  Kind: TPenKind;
  Shape: TTipShape;
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

  function ChromePanel(Parent: TWinControl; Alignment: TAlign;
    PanelClass: TChromePanelClass = nil): TPanel;
  begin
    if PanelClass = nil then PanelClass := TPanel;
    Result := PanelClass.Create(Self);
    Result.Parent := Parent;
    Result.Align := Alignment;
    Result.BevelOuter := bvNone;
    Result.ParentBackground := False;
    Result.StyleElements := Result.StyleElements - [seClient];
    Result.Color := ChromeColor;
  end;

  procedure ConnectStyleSlider(Control: THorizontalTrackBarControl);
  begin
    Control.OnChange := StyleChange;
    Control.OnMouseDown := StyleMouseDown;
    Control.OnMouseUp := StyleMouseUp;
  end;

  function Slider(const Caption: string; Min, Max: Integer; out Readout: TLabel;
    PreferredWidth: Integer): THorizontalTrackBarControl;
  begin
    Result := CreateMarkerSlider(Self, Min, Max);
    Readout := TLabel.Create(Self);
    Settings.AddSetting(Caption, Result, 34, PreferredWidth, Readout);
    ConnectStyleSlider(Result);
  end;

begin
  inherited CreateNew(nil);
  FOwnerWindow := OwnerWindow;
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
  Constraints.MinHeight := 408;
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

  Settings := TMarkerToolbar(ChromePanel(Self, alTop, TMarkerToolbar));
  Settings.Height := ToolbarHeight;
  FPenPicker := TComboBox.Create(Self);
  FPenPicker.Style := csDropDownList;
  Settings.AddSetting('ペン', FPenPicker, 84, 112);
  for Kind := Low(TPenKind) to High(TPenKind) do FPenPicker.Items.Add(PenNames[Kind]);
  FPenPicker.OnChange := PenChange;
  FSize := Slider('太さ', 1, 512, FSizeValue, 116);
  FTipPicker := TComboBox.Create(Self);
  FTipPicker.Name := 'TipPicker';
  FTipPicker.Style := csDropDownList;
  Settings.AddSetting('先端', FTipPicker, 64, 82);
  for Shape := Low(TTipShape) to High(TTipShape) do FTipPicker.Items.Add(TipNames[Shape]);
  FTipPicker.OnChange := StyleChange;
  FRotation := Slider('回転', 0, 359, FRotationValue, 92);
  FRotation.Name := 'TipRotation';
  FRotation.LargeChange := 15;

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
  ConnectStyleSlider(FColorDock.FTransparency);

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
    mtSelect: FStatus.Caption := '空いている場所からドラッグで範囲選択　線や頂点をドラッグで移動　右クリックで編集';
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
    FColorDock.FTransparency.Position := S.Transparency;
    FColorDock.FTransparencyValue.Caption := IntToStr(S.Transparency) + '%';
    FTipPicker.ItemIndex := Ord(S.Shape);
    FRotation.Enabled := S.Shape <> tsRound;
    FRotation.Position := S.Rotation;
    FRotationValue.Caption := IntToStr(FRotation.Position) + '°';
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
  EndDrag(True);
  FinishCurve;
  FinishFreehand(True);
  FTool := Tool;
  if FTool <> mtSelect then SetSelection(nil);
  SyncControls;
  FView.Invalidate;
end;

procedure TMarkerEditor.SetSelection(const Indices: TArray<Integer>);
begin
  FSelectedStrokes := Indices;
  FSelected := -1;
  FVertex := -1;
  if Length(Indices) = 0 then Exit;
  FSelected := Indices[High(Indices)];
  FStyle := FDoc.Strokes[FSelected].Style;
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
  SetSelection(nil);
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
  SetSelection(nil);
  Changed;
end;

procedure TMarkerEditor.DeleteClick(Sender: TObject);
var I, Removed: Integer; Stroke: ^TMarkerStroke;
begin
  EndDrag(False);
  if (FTool <> mtSelect) or (FSelected < 0) then Exit;
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
    Removed := 0;
    for I := FSelectedStrokes[0] to High(FDoc.Strokes) do
      if (Removed < Length(FSelectedStrokes)) and (I = FSelectedStrokes[Removed]) then
        Inc(Removed)
      else
        FDoc.Strokes[I - Removed] := FDoc.Strokes[I];
    SetLength(FDoc.Strokes, Length(FDoc.Strokes) - Removed);
    SetSelection(nil);
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
  Result := (Length(FSelectedStrokes) = 1) and (FDoc.Strokes[FSelected].Input = ikMouse) and
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

procedure TMarkerEditor.ApplyStyle(Sender: TObject; Field: TStyleField; const Value: TStrokeStyle);
var Index: Integer; Updated: TStrokeStyle; ChangedStroke: Boolean;

  procedure SetField(var Style: TStrokeStyle);
  begin
    case Field of
      sfPen: Style.Kind := Value.Kind;
      sfWidth: Style.Width := Value.Width;
      sfTransparency: Style.Transparency := Value.Transparency;
      sfTip: Style.Shape := Value.Shape;
      sfRotation: Style.Rotation := Value.Rotation;
      sfColor: Style.RGB := Value.RGB;
    end;
  end;

begin
  if FSelected < 0 then
  begin
    SetField(FStyle);
    Changed;
    Exit;
  end;

  ChangedStroke := False;
  for Index in FSelectedStrokes do
  begin
    Updated := FDoc.Strokes[Index].Style;
    SetField(Updated);
    if Updated.Matches(FDoc.Strokes[Index].Style) then Continue;
    if not ChangedStroke then
    begin
      if (FStyleGesture = Sender) and (GetCaptureControl = FStyleGesture) then
      begin
        if not FRecordedStyleGesture then
        begin
          BeginChange;
          FRecordedStyleGesture := True;
        end;
      end
      else BeginChange;
      ChangedStroke := True;
    end;
    FDoc.Strokes[Index].Style := Updated;
  end;
  if ChangedStroke then
  begin
    FStyle := CurrentStyle;
    Changed;
  end;
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
var Value: TStrokeStyle;
begin
  if FSync or (FPenPicker.ItemIndex < 0) then Exit;
  Value := CurrentStyle;
  Value.Kind := TPenKind(FPenPicker.ItemIndex);
  ApplyStyle(Sender, sfPen, Value);
end;

procedure TMarkerEditor.StyleChange(Sender: TObject);
var Value: TStrokeStyle; Field: TStyleField;
begin
  if FSync then Exit;
  Value := CurrentStyle;
  if Sender = FSize then
  begin
    Field := sfWidth;
    Value.Width := FSize.Position;
  end
  else if Sender = FColorDock.FTransparency then
  begin
    Field := sfTransparency;
    Value.Transparency := FColorDock.FTransparency.Position;
  end
  else if Sender = FRotation then
  begin
    Field := sfRotation;
    Value.Rotation := FRotation.Position;
  end
  else if FTipPicker.ItemIndex >= 0 then
  begin
    Field := sfTip;
    Value.Shape := TTipShape(FTipPicker.ItemIndex);
  end
  else Exit;
  ApplyStyle(Sender, Field, Value);
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
  FColorDock.FCode.Modified := False;
end;

procedure TMarkerEditor.ColorChange(Sender: TObject);
var Saturation, Brightness: Double; Sample: Cardinal; Value: TStrokeStyle;
begin
  if FSync then Exit;
  if Sender = FColorDock.FHue then
  begin
    ColorToSv(FColorDock.FArea.Color, Saturation, Brightness);
    FColorDock.FArea.BaseColor := FColorDock.FHue.Color;
    FColorDock.FArea.Color := HsvToColor(ColorHue(FColorDock.FHue.Color), Saturation, Brightness);
  end;
  Sample := ColorToRGB(FColorDock.FArea.Color);
  Value := CurrentStyle;
  Value.RGB := (Cardinal(GetRValue(Sample)) shl 16) or
    (Cardinal(GetGValue(Sample)) shl 8) or GetBValue(Sample);
  ApplyStyle(Sender, sfColor, Value);
end;

procedure TMarkerEditor.ColorCodeExit(Sender: TObject);
var Sample: TColor; Value: TStrokeStyle;
begin
  if FSync or not FColorDock.FCode.Modified then Exit;
  if TryParseColorCode(FColorDock.FCode.Text, Sample) then
  begin
    Value := CurrentStyle;
    Value.RGB := (Cardinal(GetRValue(Sample)) shl 16) or
      (Cardinal(GetGValue(Sample)) shl 8) or GetBValue(Sample);
    ApplyStyle(Sender, sfColor, Value);
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

function ReturnToEditor(const ErrorMessage: string): Boolean;
begin
  Result := not Application.Terminated and
    (MessageDlg(ErrorMessage + sLineBreak + sLineBreak +
      '編集画面に戻りますか？「いいえ」で未保存の変更を破棄して閉じます。',
      mtError, [mbYes, mbNo], 0, mbNo) = mrYes);
end;

procedure TMarkerEditor.EditorClose(Sender: TObject; var Action: TCloseAction);
begin
  try
    if ActiveControl = FColorDock.FCode then ColorCodeExit(FColorDock.FCode);
    FStyleGesture := nil;
    FRenderValid := False;
    EndDrag(False);
    FinishFreehand(False);
    FinishCurve;
    FClosingJSON := WriteDocument(FDoc);
  except
    on E: Exception do
      if ReturnToEditor(E.Message) then Action := caNone;
  end;
end;

function TMarkerEditor.IsShortCut(var Message: TWMKey): Boolean;
begin
  // 数値欄にフォーカスがある場合は文字の削除を優先する。
  if (Message.CharCode = VK_DELETE) and (ActiveControl <> FView) then Exit(False);
  Result := inherited IsShortCut(Message);
end;

procedure TMarkerEditor.MouseWheelHandler(var Message: TMessage);
var Target: TWinControl;
begin
  if FColorDock = nil then
  begin
    inherited;
    Exit;
  end;
  Target := FindVCLWindow(SmallPointToPoint(TWMMouseWheel(Message).Pos));
  if (Target <> nil) and Target.Enabled and ((Target = FSize) or (Target = FRotation) or
    (Target = FColorDock.FTransparency)) then
  begin
    if ActiveControl = FColorDock.FCode then ColorCodeExit(FColorDock.FCode);
    Message.Result := Target.Perform(CM_MOUSEWHEEL, Message.WParam, Message.LParam);
    if Message.Result <> 0 then Exit;
  end;
  inherited;
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

function TMarkerEditor.MarqueeBounds: TRect;
begin
  Result := Rect(Min(FMarqueeStart.X, FMarqueeEnd.X), Min(FMarqueeStart.Y, FMarqueeEnd.Y),
    Max(FMarqueeStart.X, FMarqueeEnd.X) + 1, Max(FMarqueeStart.Y, FMarqueeEnd.Y) + 1);
  Result.Intersect(FContent);
end;

procedure TMarkerEditor.SelectInRect(const Bounds: TRect);
var
  World: TRectF;
  Selection: TArray<Integer>;
  A, B: TPointF;
  I, J, Count: Integer;

  function ClipAxis(Origin, Delta, Lower, Upper: Single; var First, Last: Single): Boolean;
  var T0, T1: Single;
  begin
    if Delta = 0 then Exit((Origin >= Lower) and (Origin <= Upper));
    T0 := (Lower - Origin) / Delta;
    T1 := (Upper - Origin) / Delta;
    First := Max(First, Min(T0, T1));
    Last := Min(Last, Max(T0, T1));
    Result := First <= Last;
  end;

  function CrossesBounds(const StartPoint, EndPoint: TPointF): Boolean;
  var First, Last: Single;
  begin
    First := 0;
    Last := 1;
    Result := ClipAxis(StartPoint.X, EndPoint.X - StartPoint.X, World.Left, World.Right, First, Last) and
      ClipAxis(StartPoint.Y, EndPoint.Y - StartPoint.Y, World.Top, World.Bottom, First, Last);
  end;

begin
  if Bounds.IsEmpty then
  begin
    SetSelection(nil);
    Exit;
  end;
  World := TRectF.Create(ToWorld(Bounds.Left, Bounds.Top), ToWorld(Bounds.Right, Bounds.Bottom));
  EnsurePaths;
  SetLength(Selection, Length(FPaths));
  Count := 0;
  for I := 0 to High(FPaths) do
  begin
    if Length(FPaths[I].Points) = 0 then Continue;
    A := FPaths[I].Points[0].Position;
    if not World.Contains(A) then
    begin
      J := 1;
      while J <= High(FPaths[I].Points) do
      begin
        B := FPaths[I].Points[J].Position;
        if CrossesBounds(A, B) then Break;
        A := B;
        Inc(J);
      end;
      if J > High(FPaths[I].Points) then Continue;
    end;
    Selection[Count] := I;
    Inc(Count);
  end;
  SetLength(Selection, Count);
  SetSelection(Selection);
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
  if Length(FSelectedStrokes) <> 1 then Exit;
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
  if FTool = mtFreehand then
  begin
    if not FContent.Contains(Point(X, Y)) then Exit;
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
    if FContent.Contains(Point(X, Y)) then
      for I := High(FPaths) downto 0 do
      begin
        Limit := Max(MulDiv(8, FView.CurrentPPI, 96), FPaths[I].Style.Width *
          Min(FContent.Width / FDoc.Width, FContent.Height / FDoc.Height) *
          TipExtent[FPaths[I].Style.Shape] / 2 +
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
    if Hit >= 0 then
    begin
      if (Button <> mbRight) or (not TArray.Contains<Integer>(FSelectedStrokes, Hit)) then
        SetSelection([Hit]);
      if InsertWithClick then
        if InsertVertex(HitSegment, HitT) then Exit;
      if not InsertWithClick then FDragging := HitSelectedPoint(X, Y, False, FVertex);
      if FDragging = dpNone then FDragging := dpStroke;
    end
    else if Button = mbLeft then
    begin
      FMarqueeStart := Point(X, Y);
      FMarqueeEnd := FMarqueeStart;
      FDragging := dpMarquee;
      SetCapture(FView.Handle);
      Exit;
    end
    else SetSelection(nil);
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
  if FDragging = dpMarquee then
  begin
    FMarqueeEnd := Point(X, Y);
    FView.Invalidate;
    Exit;
  end;
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
var Part: TDragPart; Threshold: Integer;
begin
  if FDragging = dpNone then Exit;
  Part := FDragging;
  FDragging := dpNone;
  if GetCapture = FView.Handle then ReleaseCapture;
  if Part = dpMarquee then
  begin
    if not Cancel then
    begin
      Threshold := MulDiv(3, FView.CurrentPPI, 96);
      if Max(Abs(FMarqueeEnd.X - FMarqueeStart.X), Abs(FMarqueeEnd.Y - FMarqueeStart.Y)) >= Threshold then
        SelectInRect(MarqueeBounds)
      else SetSelection(nil);
      SyncControls;
    end;
    FView.Invalidate;
    Exit;
  end;
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
const
  OutlineColor = TColor($00191410);
  HighlightColor = TColor($00FFE370);
var
  A: TCurveAnchor;
  P: TPoint;
  Index, I, PPI, HandleRadius, VertexRadius: Integer;
  Path: TMarkerPath;
  Points: TArray<TPoint>;
  HasLength: Boolean;
  Bounds: TRect;
  C: TCanvas;
  DC: HDC;
  OutlinePen, HighlightPen: HPEN;

  function DashedPen(Color: TColor; Width: Integer): HPEN;
  var Brush: TLogBrush; Dashes: array[0..1] of DWORD;
  begin
    Brush := Default(TLogBrush);
    Brush.lbStyle := BS_SOLID;
    Brush.lbColor := ColorToRGB(Color);
    Dashes[0] := MulDiv(12, PPI, 96);
    Dashes[1] := MulDiv(8, PPI, 96);
    Result := ExtCreatePen(PS_GEOMETRIC or PS_USERSTYLE or PS_ENDCAP_FLAT or PS_JOIN_ROUND,
      MulDiv(Width, PPI, 96), Brush, Length(Dashes), @Dashes[0]);
  end;

  procedure DashedOutline(const Line: array of TPoint);
  var PreviousPen: HGDIOBJ; PreviousMode: Integer;
  begin
    PreviousMode := SetBkMode(DC, TRANSPARENT);
    PreviousPen := SelectObject(DC, OutlinePen);
    try
      Winapi.Windows.Polyline(DC, Line[0], Length(Line));
      SelectObject(DC, HighlightPen);
      Winapi.Windows.Polyline(DC, Line[0], Length(Line));
    finally
      SelectObject(DC, PreviousPen);
      SetBkMode(DC, PreviousMode);
    end;
  end;

  procedure SetPen(Color: TColor; Width: Integer);
  begin
    C.Pen.Color := Color;
    C.Pen.Width := MulDiv(Width, PPI, 96);
  end;

  procedure PointOutline(const Center: TPoint);
  var Radius: Integer;
  begin
    Radius := MulDiv(6, PPI, 96);
    C.Brush.Style := bsClear;
    SetPen(OutlineColor, 7);
    C.Ellipse(Center.X - Radius, Center.Y - Radius, Center.X + Radius + 1, Center.Y + Radius + 1);
    SetPen(HighlightColor, 3);
    C.Ellipse(Center.X - Radius, Center.Y - Radius, Center.X + Radius + 1, Center.Y + Radius + 1);
    C.Brush.Style := bsSolid;
  end;

  procedure Handle(const Offset: TPointF);
  var H: TPoint;
  begin
    H := ToView(A.Position + Offset);
    SetPen(OutlineColor, 5);
    C.Polyline([P, H]);
    SetPen(HighlightColor, 2);
    C.Polyline([P, H]);
    SetPen(OutlineColor, 2);
    C.Brush.Color := HighlightColor;
    C.Ellipse(H.X - HandleRadius, H.Y - HandleRadius,
      H.X + HandleRadius + 1, H.Y + HandleRadius + 1);
  end;

begin
  if (FTool <> mtSelect) or ((FSelected < 0) and (FDragging <> dpMarquee)) then Exit;
  PPI := FView.CurrentPPI;
  C := FView.Canvas;
  DC := C.Handle;
  OutlinePen := DashedPen(OutlineColor, 7);
  HighlightPen := DashedPen(HighlightColor, 3);
  try
    if (OutlinePen = 0) or (HighlightPen = 0) then Exit;
    for Index in FSelectedStrokes do
    begin
      Path := FPaths[Index];
      if Length(Path.Points) = 0 then Continue;
      SetLength(Points, Length(Path.Points));
      Points[0] := ToView(Path.Points[0].Position);
      HasLength := False;
      for I := 1 to High(Points) do
      begin
        Points[I] := ToView(Path.Points[I].Position);
        HasLength := HasLength or (Points[I] <> Points[0]);
      end;
      if HasLength then DashedOutline(Points)
      else PointOutline(Points[0]);
    end;
    if FDragging = dpMarquee then
    begin
      Bounds := MarqueeBounds;
      if not Bounds.IsEmpty then
        DashedOutline([Bounds.TopLeft, Point(Bounds.Right - 1, Bounds.Top),
          Point(Bounds.Right - 1, Bounds.Bottom - 1), Point(Bounds.Left, Bounds.Bottom - 1), Bounds.TopLeft]);
    end;
    if Length(FSelectedStrokes) <> 1 then Exit;
    HandleRadius := MulDiv(4, PPI, 96);
    VertexRadius := MulDiv(5, PPI, 96);
    for I := 0 to High(FDoc.Strokes[FSelected].Anchors) do
    begin
      A := FDoc.Strokes[FSelected].Anchors[I];
      P := ToView(A.Position);
      SetPen(OutlineColor, 2);
      C.Brush.Color := clWhite;
      if I = FVertex then
      begin
        C.Brush.Color := HighlightColor;
        if I > 0 then Handle(A.InHandle);
        if I < High(FDoc.Strokes[FSelected].Anchors) then Handle(A.OutHandle);
      end;
      if A.Kind = akSmooth then
        C.Ellipse(P.X - VertexRadius, P.Y - VertexRadius, P.X + VertexRadius + 1, P.Y + VertexRadius + 1)
      else
        C.Rectangle(P.X - VertexRadius, P.Y - VertexRadius, P.X + VertexRadius + 1, P.Y + VertexRadius + 1);
    end;
  finally
    C.Pen.Width := 1;
    DeleteObject(HighlightPen);
    DeleteObject(OutlinePen);
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
    Editor := TMarkerEditor.CreateEditor(OwnerWindow, Document, Background);
    try
      repeat
        Editor.FClosingJSON := '';
        Editor.ShowModal;
        if Editor.FClosingJSON = '' then Break;
        // The owner is re-enabled after ShowModal. AviUtl2 may update its
        // windows while the edit section commits the data.
        try
          if Save(Editor.FClosingJSON) then Break;
          raise EInvalidOp.Create('描画データを保存できませんでした。');
        except
          on E: Exception do
            if not ReturnToEditor(E.Message) then Break;
        end;
      until Application.Terminated;
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
