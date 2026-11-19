unit DrawMarker_Editor;

interface

uses
  Winapi.Windows, Winapi.Messages, System.Types, System.Classes, System.Generics.Collections,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics, Vcl.Samples.Spin,
  DrawMarker_Model, DrawMarker_Curves, DrawMarker_Renderer, DrawMarker_Capture;

type
  TMarkerSave = function(const JSON: string): Boolean of object;

procedure OpenMarkerEditor(OwnerWindow: HWND; const Document: TMarkerDocument;
  const Background: TMarkerCapture; Save: TMarkerSave);

implementation

uses System.SysUtils, System.Math, System.UITypes, Vcl.Dialogs, Vcl.Menus, AviUtl2FilterTypes;

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
    FUndo, FRedo: TList<TMarkerDocument>;
    FSelected, FVertex: Integer;
    FDragging: TDragPart;
    FBeforeDrag: TMarkerDocument;
    FDragOrigin: TPointF;
    FDragChanged: Boolean;
    FSelectMode: Boolean;
    FStyle: TStrokeStyle;
    FPending: TArray<TCurveAnchor>;
    FPenSamples: TList<TPenSample>;
    FPenID, FPenStart: Cardinal;
    FHover: TPointF;
    FHovering: Boolean;
    FSync: Boolean;
    FUndoButton, FRedoButton, FDeleteButton, FKindButton, FDrawButton,
      FSelectButton, FColorButton: TButton;
    FPenPicker: TComboBox;
    FSize, FOpacity: TSpinEdit;
    FPressure: TCheckBox;
    FStatus: TLabel;
    procedure SetStatus;
    procedure SyncControls;
    procedure Changed;
    procedure EnsurePaths;
    procedure BeginChange;
    procedure PushUndo(const Before: TMarkerDocument);
    procedure AddStroke(const Stroke: TMarkerStroke);
    procedure FinishCurve;
    procedure SelectTool(Sender: TObject);
    procedure UndoClick(Sender: TObject);
    procedure RedoClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure KindClick(Sender: TObject);
    procedure ColorClick(Sender: TObject);
    procedure PenChange(Sender: TObject);
    procedure StyleChange(Sender: TObject);
    procedure ApplyStyle;
    procedure SaveClick(Sender: TObject);
    procedure EditorKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ViewDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure ViewMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure ViewUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure EndDrag(Cancel: Boolean);
    function HandlePointer(const Msg: TMessage): Boolean;
    procedure AddPenHistory(ID: Cardinal; const Pen: POINTER_PEN_INFO; IncludeHistory: Boolean);
    function ToWorld(X, Y: Integer): TPointF;
    function ToView(const P: TPointF): TPoint;
    function HitSelectedPoint(X, Y: Integer; out Index: Integer): TDragPart;
    procedure DrawView;
    procedure DrawSelection;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  public
    constructor CreateEditor(OwnerWindow: HWND; const Document: TMarkerDocument;
      const Background: TMarkerCapture; Save: TMarkerSave);
    destructor Destroy; override;
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
      WM_CAPTURECHANGED: FEditor.EndDrag(True);
      CM_MOUSELEAVE:
        begin
          FEditor.FHovering := False;
          if Length(FEditor.FPending) > 0 then Invalidate;
        end;
    end;
  inherited;
end;

constructor TMarkerEditor.CreateEditor(OwnerWindow: HWND; const Document: TMarkerDocument;
  const Background: TMarkerCapture; Save: TMarkerSave);
var Bar, Settings, Footer: TPanel; CancelButton, Done: TButton; Kind: TPenKind;

  function Button(Parent: TWinControl; const Caption: string; X, W: Integer;
    Action: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Parent;
    Result.SetBounds(X, 6, W, 28);
    Result.Caption := Caption;
    Result.OnClick := Action;
  end;

  procedure LabelAt(Parent: TWinControl; const Caption: string; X, Y: Integer);
  var L: TLabel;
  begin
    L := TLabel.Create(Self);
    L.Parent := Parent;
    L.Caption := Caption;
    L.SetBounds(X, Y, 1, 20);
  end;

  function Spin(X, Min, Max: Integer): TSpinEdit;
  begin
    Result := TSpinEdit.Create(Self);
    Result.Parent := Settings;
    Result.SetBounds(X, 8, 61, 25);
    Result.MinValue := Min;
    Result.MaxValue := Max;
    Result.OnExit := StyleChange;
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
  FPenSamples := TList<TPenSample>.Create;
  FSelected := -1;
  FVertex := -1;
  FStyle := DefaultStyle(pkNormal);
  FStyle.Width := EnsureRange(Round(FStyle.Width * FDoc.Width / 1920), 2, 512);
  Caption := '手描きマーカー';
  Font.Name := 'Yu Gothic UI';
  Font.Size := 10;
  BorderStyle := bsSizeable;
  Position := poScreenCenter;
  ClientWidth := 970;
  ClientHeight := 660;
  Constraints.MinWidth := 700;
  Constraints.MinHeight := 430;
  KeyPreview := True;
  OnKeyDown := EditorKey;
  DoubleBuffered := True;

  Bar := TPanel.Create(Self);
  Bar.Parent := Self;
  Bar.Align := alTop;
  Bar.Height := 40;
  Bar.BevelOuter := bvNone;
  FDrawButton := Button(Bar, '描画', 12, 78, SelectTool);
  FSelectButton := Button(Bar, '選択', 94, 78, SelectTool);
  FUndoButton := Button(Bar, '元に戻す', 194, 96, UndoClick);
  FRedoButton := Button(Bar, 'やり直す', 294, 96, RedoClick);
  FDeleteButton := Button(Bar, '削除', 410, 72, DeleteClick);
  FKindButton := Button(Bar, '頂点の種類', 486, 116, KindClick);

  Settings := TPanel.Create(Self);
  Settings.Parent := Self;
  Settings.Top := Bar.Height;
  Settings.Align := alTop;
  Settings.Height := 42;
  Settings.BevelOuter := bvNone;
  FPenPicker := TComboBox.Create(Self);
  FPenPicker.Parent := Settings;
  FPenPicker.Style := csDropDownList;
  FPenPicker.SetBounds(12, 8, 138, 25);
  for Kind := Low(TPenKind) to High(TPenKind) do FPenPicker.Items.Add(PenNames[Kind]);
  FPenPicker.OnChange := PenChange;
  FColorButton := Button(Settings, '色', 160, 100, ColorClick);
  LabelAt(Settings, '太さ', 274, 10);
  FSize := Spin(312, 1, 512);
  LabelAt(Settings, '不透明度 %', 386, 10);
  FOpacity := Spin(469, 0, 100);
  FPressure := TCheckBox.Create(Self);
  FPressure.Parent := Settings;
  FPressure.SetBounds(544, 8, 130, 26);
  FPressure.Caption := '筆圧で太さを変える';
  FPressure.OnClick := StyleChange;

  Footer := TPanel.Create(Self);
  Footer.Parent := Self;
  Footer.Align := alBottom;
  Footer.Height := 46;
  Footer.BevelOuter := bvNone;
  FStatus := TLabel.Create(Self);
  FStatus.Parent := Footer;
  FStatus.SetBounds(12, 12, 1, 22);
  Done := Button(Footer, '反映', ClientWidth - 180, 76, SaveClick);
  Done.Anchors := [akTop, akRight];
  CancelButton := Button(Footer, 'キャンセル', ClientWidth - 100, 88, nil);
  CancelButton.Anchors := [akTop, akRight];
  CancelButton.ModalResult := mrCancel;

  FView := TMarkerCanvas.Create(Self);
  FView.FEditor := Self;
  FView.ControlStyle := FView.ControlStyle - [csCaptureMouse];
  FView.Parent := Self;
  FView.Align := alClient;
  FView.DoubleBuffered := True;
  FView.TabStop := True;
  FView.OnMouseDown := ViewDown;
  FView.OnMouseMove := ViewMove;
  FView.OnMouseUp := ViewUp;
  SyncControls;
end;

destructor TMarkerEditor.Destroy;
begin
  if FView <> nil then FView.FEditor := nil;
  FPenSamples.Free;
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
  if FSelectMode then
    FStatus.Caption := '線・頂点・ハンドルをドラッグ　Ctrl+クリックで頂点を追加'
  else
    FStatus.Caption := 'マウスは左クリックで頂点、右クリックで確定　ペンは手描き';
  if Length(FBackground.Pixels) = 0 then FStatus.Caption := '背景を取得できませんでした。 ' + FStatus.Caption;
end;

procedure TMarkerEditor.SyncControls;
var S: TStrokeStyle;
begin
  FSync := True;
  try
    S := FStyle;
    if FSelectMode and (FSelected >= 0) then S := FDoc.Strokes[FSelected].Style;
    FPenPicker.ItemIndex := Ord(S.Kind);
    FColorButton.Caption := '色 #' + IntToHex(S.RGB, 6);
    FSize.Value := Round(S.Width);
    FOpacity.Value := S.Opacity;
    FPressure.Checked := S.UsePressure;
    FDrawButton.Enabled := FSelectMode;
    FSelectButton.Enabled := not FSelectMode;
    FDeleteButton.Enabled := FSelectMode and (FSelected >= 0);
    FKindButton.Enabled := FDeleteButton.Enabled and (FVertex >= 0);
    if FKindButton.Enabled then
      if FDoc.Strokes[FSelected].Anchors[FVertex].Kind = akSmooth then
        FKindButton.Caption := '鋭角頂点にする'
      else FKindButton.Caption := 'ベジェ頂点にする'
    else FKindButton.Caption := '頂点の種類';
    FUndoButton.Enabled := (FUndo.Count > 0) or (Length(FPending) > 0);
    FRedoButton.Enabled := FRedo.Count > 0;
    SetStatus;
  finally
    FSync := False;
  end;
end;

procedure TMarkerEditor.Changed;
begin
  FPathsDirty := True;
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
begin
  if Length(FDoc.Strokes) >= MaxMarkerStrokes then Exit;
  if PointCount(FDoc) + Length(Stroke.Anchors) + Length(Stroke.Samples) > MaxMarkerPoints then Exit;
  BeginChange;
  SetLength(FDoc.Strokes, Length(FDoc.Strokes) + 1);
  FDoc.Strokes[High(FDoc.Strokes)] := Stroke;
  Changed;
end;

procedure TMarkerEditor.FinishCurve;
var Stroke: TMarkerStroke; I: Integer;
begin
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
begin
  if Sender = FSelectButton then FinishCurve;
  FSelectMode := Sender = FSelectButton;
  if not FSelectMode then
  begin
    FSelected := -1;
    FVertex := -1;
  end;
  SyncControls;
  FView.Invalidate;
end;

procedure TMarkerEditor.UndoClick(Sender: TObject);
begin
  if Length(FPending) > 0 then
  begin
    SetLength(FPending, Length(FPending) - 1);
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
  if not FSelectMode or (FSelected < 0) then Exit;
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
  if not FSelectMode or (FVertex < 0) then Exit;
  BeginChange;
  Stroke := @FDoc.Strokes[FSelected];
  Stroke^.Anchors := Copy(Stroke^.Anchors);
  if Stroke^.Anchors[FVertex].Kind = akSmooth then Kind := akCorner else Kind := akSmooth;
  SetAnchorKind(Stroke^.Anchors, FVertex, Kind);
  Changed;
end;

procedure TMarkerEditor.ApplyStyle;
var S: TStrokeStyle;
begin
  if FSelectMode and (FSelected >= 0) then
  begin
    S := FDoc.Strokes[FSelected].Style;
    if (S.Kind = FStyle.Kind) and (S.RGB = FStyle.RGB) and (S.Width = FStyle.Width) and
      (S.Opacity = FStyle.Opacity) and (S.UsePressure = FStyle.UsePressure) then Exit;
    BeginChange;
    FDoc.Strokes[FSelected].Style := FStyle;
  end;
  Changed;
end;

procedure TMarkerEditor.PenChange(Sender: TObject);
begin
  if FSync or (FPenPicker.ItemIndex < 0) then Exit;
  FStyle := DefaultStyle(TPenKind(FPenPicker.ItemIndex));
  FStyle.Width := EnsureRange(Round(FStyle.Width * FDoc.Width / 1920), 2, 512);
  ApplyStyle;
end;

procedure TMarkerEditor.StyleChange(Sender: TObject);
begin
  if FSync then Exit;
  if FSelectMode and (FSelected >= 0) then FStyle := FDoc.Strokes[FSelected].Style;
  FStyle.Width := EnsureRange(FSize.Value, 1, 512);
  FStyle.Opacity := EnsureRange(FOpacity.Value, 0, 100);
  FStyle.UsePressure := FPressure.Checked;
  ApplyStyle;
end;

procedure TMarkerEditor.ColorClick(Sender: TObject);
var D: TColorDialog; C: Cardinal;
begin
  if FSelectMode and (FSelected >= 0) then FStyle := FDoc.Strokes[FSelected].Style;
  D := TColorDialog.Create(Self);
  try
    C := FStyle.RGB;
    D.Color := RGB(C shr 16, (C shr 8) and 255, C and 255);
    if D.Execute then
    begin
      C := ColorToRGB(D.Color);
      FStyle.RGB := (Cardinal(GetRValue(C)) shl 16) or
        (Cardinal(GetGValue(C)) shl 8) or GetBValue(C);
      ApplyStyle;
    end;
  finally
    D.Free;
  end;
end;

procedure TMarkerEditor.SaveClick(Sender: TObject);
begin
  FinishCurve;
  try
    if FSave(WriteDocument(FDoc)) then ModalResult := mrOK;
  except
    on E: Exception do MessageDlg(E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TMarkerEditor.EditorKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (ssCtrl in Shift) and (Key = Ord('Z')) then
  begin
    if ssShift in Shift then RedoClick(nil) else UndoClick(nil);
  end
  else if (ssCtrl in Shift) and (Key = Ord('Y')) then RedoClick(nil)
  else if (Key = VK_DELETE) and (ActiveControl = FView) then DeleteClick(nil)
  else if (Key = VK_RETURN) and (Length(FPending) > 0) then FinishCurve
  else if (Key = VK_ESCAPE) and (FDragging <> dpNone) then EndDrag(True)
  else if (Key = VK_ESCAPE) and (Length(FPending) > 0) then
  begin
    FPending := nil;
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

function TMarkerEditor.HitSelectedPoint(X, Y: Integer; out Index: Integer): TDragPart;
var A: TCurveAnchor; P: TPoint; I: Integer;
  function Near(const Pos: TPointF): Boolean;
  begin
    P := ToView(Pos);
    Result := (Abs(P.X - X) <= 7) and (Abs(P.Y - Y) <= 7);
  end;
begin
  Result := dpNone;
  Index := -1;
  if FSelected < 0 then Exit;
  for I := 0 to High(FDoc.Strokes[FSelected].Anchors) do
    if Near(FDoc.Strokes[FSelected].Anchors[I].Position) then
    begin
      Index := I;
      Exit(dpVertex);
    end;
  if FVertex < 0 then Exit;
  A := FDoc.Strokes[FSelected].Anchors[FVertex];
  Index := FVertex;
  if (FVertex > 0) and Near(A.Position + A.InHandle) then Exit(dpIncoming);
  if (FVertex < High(FDoc.Strokes[FSelected].Anchors)) and Near(A.Position + A.OutHandle) then Exit(dpOutgoing);
  Index := -1;
end;

procedure TMarkerEditor.ViewDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var P: TPointF; I, Segment, Hit, HitSegment, Index: Integer; T, HitT, Limit: Single;
  Popup: TPopupMenu; MenuItem: TMenuItem;
begin
  if not FSelectMode and (PromotedMouse or (FPenID <> 0)) then Exit;
  FView.SetFocus;
  if not FSelectMode and (Button = mbRight) then
  begin
    FinishCurve;
    Exit;
  end;
  if not FContent.Contains(Point(X, Y)) then Exit;
  P := ToWorld(X, Y);
  if not FSelectMode then
  begin
    if (Button = mbLeft) and (Length(FPending) < MaxStrokePoints) then
    begin
      if (Length(FPending) > 0) and (Magnitude(FPending[High(FPending)].Position - P) < 0.01) then Exit;
      SetLength(FPending, Length(FPending) + 1);
      FPending[High(FPending)].Position := P;
      SyncControls;
      FView.Invalidate;
    end;
    Exit;
  end;
  if not (Button in [mbLeft, mbRight]) then Exit;
  FDragging := dpNone;
  if not (ssCtrl in Shift) then FDragging := HitSelectedPoint(X, Y, Index);
  if FDragging <> dpNone then FVertex := Index
  else
  begin
    EnsurePaths;
    Hit := -1;
    HitSegment := -1;
    HitT := 0;
    for I := High(FPaths) downto 0 do
    begin
      Limit := Max(8, FPaths[I].Style.Width * Min(FContent.Width / FDoc.Width,
        FContent.Height / FDoc.Height) / 2 + 4);
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
      if (ssCtrl in Shift) and (Button = mbLeft) and (FDoc.Strokes[Hit].Input = ikMouse)
        and (HitSegment >= 0) and (HitT > 0.001) and (HitT < 0.999)
        and (Length(FDoc.Strokes[Hit].Anchors) < MaxStrokePoints) and (PointCount(FDoc) < MaxMarkerPoints) then
      begin
        BeginChange;
        FDoc.Strokes[Hit].Anchors := Copy(FDoc.Strokes[Hit].Anchors);
        SplitCurve(FDoc.Strokes[Hit].Anchors, HitSegment, HitT);
        FVertex := HitSegment + 1;
        Changed;
        Exit;
      end;
      FDragging := dpStroke;
    end;
  end;
  SyncControls;
  FView.Invalidate;
  if (Button = mbRight) and (FSelected >= 0) then
  begin
    FDragging := dpNone;
    Popup := TPopupMenu.Create(Self);
    try
      MenuItem := TMenuItem.Create(Popup);
      if FVertex >= 0 then MenuItem.Caption := '頂点を削除' else MenuItem.Caption := '一画を削除';
      MenuItem.OnClick := DeleteClick;
      Popup.Items.Add(MenuItem);
      if FVertex >= 0 then
      begin
        MenuItem := TMenuItem.Create(Popup);
        MenuItem.Caption := FKindButton.Caption;
        MenuItem.OnClick := KindClick;
        Popup.Items.Add(MenuItem);
      end;
      with FView.ClientToScreen(Point(X, Y)) do Popup.Popup(X, Y);
    finally
      Popup.Free;
    end;
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
  if not FSelectMode then
  begin
    if PromotedMouse or (Length(FPending) = 0) then Exit;
    FHover := ToWorld(X, Y);
    FHovering := FContent.Contains(Point(X, Y));
    FView.Invalidate;
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
  FView.Invalidate;
end;

procedure TMarkerEditor.ViewUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button = mbLeft then EndDrag(False);
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

procedure TMarkerEditor.AddPenHistory(ID: Cardinal; const Pen: POINTER_PEN_INFO;
  IncludeHistory: Boolean);
var History: TArray<POINTER_PEN_INFO>; Count: Cardinal; I: Integer;
  procedure Append(const Info: POINTER_PEN_INFO);
  var Sample: TPenSample; P: TPoint; T: UInt64;
  begin
    if FPenSamples.Count >= MaxStrokePoints then Exit;
    T := (UInt64(Info.pointerInfo.dwTime) + UInt64($100000000) - FPenStart) and UInt64($FFFFFFFF);
    if T > 86400000 then Exit;
    P := FView.ScreenToClient(Info.pointerInfo.ptPixelLocation);
    Sample.Position := ToWorld(P.X, P.Y);
    Sample.Milliseconds := Integer(T);
    Sample.Pressure := 1;
    if (Info.penMask and PEN_MASK_PRESSURE) <> 0 then
      Sample.Pressure := Min(1.0, Info.pressure / 1024);
    if FPenSamples.Count > 0 then
    begin
      if Sample.Milliseconds < FPenSamples.Last.Milliseconds then Exit;
      if (Sample.Milliseconds = FPenSamples.Last.Milliseconds) and
        (Sample.Position = FPenSamples.Last.Position) and
        (Sample.Pressure = FPenSamples.Last.Pressure) then Exit;
    end;
    FPenSamples.Add(Sample);
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
var ID: Cardinal; Pen: POINTER_PEN_INFO; P: TPoint; Stroke: TMarkerStroke;
begin
  Result := False;
  if FSelectMode then Exit;
  ID := LoWord(Msg.WParam);
  if Msg.Msg = WM_POINTERCAPTURECHANGED then
  begin
    if ID = FPenID then
    begin
      FPenID := 0;
      FPenSamples.Clear;
      FView.Invalidate;
      Result := True;
    end;
    Exit;
  end;
  if not GetPointerPenInfo(ID, @Pen) then Exit;
  Result := True;
  if Msg.Msg = WM_POINTERDOWN then
  begin
    if FPenID <> 0 then Exit;
    P := FView.ScreenToClient(Pen.pointerInfo.ptPixelLocation);
    if not FContent.Contains(P) then Exit;
    FinishCurve;
    FView.SetFocus;
    FPenID := ID;
    FPenStart := Pen.pointerInfo.dwTime;
    FPenSamples.Clear;
  end;
  if ID <> FPenID then Exit;
  AddPenHistory(ID, Pen, Msg.Msg <> WM_POINTERDOWN);
  if Msg.Msg = WM_POINTERUP then
  begin
    FPenID := 0;
    Stroke.Input := ikPen;
    Stroke.Style := FStyle;
    Stroke.Samples := FPenSamples.ToArray;
    FPenSamples.Clear;
    if Length(Stroke.Samples) > 0 then AddStroke(Stroke);
  end;
  FView.Invalidate;
end;

procedure TMarkerEditor.DrawSelection;
var
  A: TCurveAnchor;
  P, H: TPoint;
  I: Integer;
  Path: TMarkerPath;
  C: TCanvas;
  procedure Handle(const Offset: TPointF);
  begin
    H := ToView(A.Position + Offset);
    C.MoveTo(P.X, P.Y);
    C.LineTo(H.X, H.Y);
    C.Ellipse(H.X - 4, H.Y - 4, H.X + 5, H.Y + 5);
  end;
begin
  if not FSelectMode or (FSelected < 0) then Exit;
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
    if A.Kind = akSmooth then C.Ellipse(P.X - 5, P.Y - 5, P.X + 6, P.Y + 6)
    else C.Rectangle(P.X - 5, P.Y - 5, P.X + 6, P.Y + 6);
  end;
end;

procedure ComposeMarkerPreview(Bitmap: TBitmap; const Markers: TRGBAPixels;
  const Background: TMarkerCapture; Width, Height: Integer);
var
  X, Y, I, J, K, Alpha, BackgroundAlpha, Base: Integer;
  Fore, Back: TPIXEL_RGBA;
  Line: PCardinal;
  R, G, B: Integer;
begin
  if (Width <> Bitmap.Width) or (Height <> Bitmap.Height) then Bitmap.SetSize(Width, Height);
  I := 0;
  for Y := 0 to Height - 1 do
  begin
    // VCL は DIB の向きを補正し、ScanLine[0] を表示上の先頭行として返す。
    Line := Bitmap.ScanLine[Y];
    J := (Y * Background.Height div Height) * Background.Width;
    for X := 0 to Width - 1 do
    begin
      Base := 47 + ((X div 16 + Y div 16) and 1) * 18;
      Back := Default(TPIXEL_RGBA);
      if Length(Background.Pixels) > 0 then
      begin
        K := J + X * Background.Width div Width;
        Back := Background.Pixels[K];
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
  W, H, FitWidth, FitHeight, I: Integer;
  Scale: Double;
  DrawPaths: TMarkerPaths;
  Temp: TMarkerStroke;
  Pixels: TRGBAPixels;
begin
  FView.Canvas.Brush.Color := $0024201E;
  FView.Canvas.FillRect(FView.ClientRect);
  if (FView.Width < 30) or (FView.Height < 30) then Exit;
  FitWidth := FDoc.Width;
  FitHeight := FDoc.Height;
  if Length(FBackground.Pixels) > 0 then
  begin
    FitWidth := FBackground.Width;
    FitHeight := FBackground.Height;
  end;
  Scale := Min((FView.Width - 24) / FitWidth, (FView.Height - 24) / FitHeight);
  W := Max(1, Round(FitWidth * Scale));
  H := Max(1, Round(FitHeight * Scale));
  FContent := Rect((FView.Width - W) div 2, (FView.Height - H) div 2,
    (FView.Width - W) div 2 + W, (FView.Height - H) div 2 + H);
  EnsurePaths;
  DrawPaths := FPaths;
  if (Length(FPending) > 0) or (FPenSamples.Count > 0) then
  begin
    Temp.Style := FStyle;
    if FPenSamples.Count > 0 then
    begin
      Temp.Input := ikPen;
      Temp.Samples := FPenSamples.ToArray;
    end
    else
    begin
      Temp.Input := ikMouse;
      Temp.Anchors := Copy(FPending);
      if FHovering then
      begin
        SetLength(Temp.Anchors, Length(Temp.Anchors) + 1);
        Temp.Anchors[High(Temp.Anchors)].Position := FHover;
      end;
      for I := 0 to High(Temp.Anchors) do SetAutomaticHandles(Temp.Anchors, I);
    end;
    SetLength(DrawPaths, Length(DrawPaths) + 1);
    DrawPaths[High(DrawPaths)] := BuildPath(Temp, FDoc.Width);
  end;
  Pixels := FRenderer.Render(DrawPaths, FDoc.Width, FDoc.Height, W, H, 1E20);
  if Length(Pixels) = 0 then Exit;
  ComposeMarkerPreview(FBitmap, Pixels, FBackground, W, H);
  FView.Canvas.Draw(FContent.Left, FContent.Top, FBitmap);
  DrawSelection;
end;

procedure OpenMarkerEditor(OwnerWindow: HWND; const Document: TMarkerDocument;
  const Background: TMarkerCapture; Save: TMarkerSave);
var Editor: TMarkerEditor;
begin
  Editor := TMarkerEditor.CreateEditor(OwnerWindow, Document, Background, Save);
  try
    Editor.ShowModal;
  finally
    Editor.Free;
  end;
end;

end.
