unit DrawMarker_Renderer;

interface

uses DrawMarker_Curves, DrawMarker_Model, AviUtl2FilterTypes, System.Types;

type
  TMarkerRenderer = class
  private
    FWidth, FHeight, FTilesAcross: Integer;
    FScaleX, FScaleY, FWidthScale: Single;
    FPixels: TRGBAPixels;
    FCoverage: TArray<Byte>;
    FTileMinimum: TArray<Byte>;
    FTilesUsed: Boolean;
    FTouched: TArray<Integer>;
    FCount: Integer;
    FPreviewBase: TRGBAPixels;
    FPreviewDirty: TArray<Boolean>;
    FPreviewStyle: TStrokeStyle;
    FPreviewPoints: Integer;
    procedure ClearTileMinimum;
    procedure ResetPreview;
    procedure MarkCapsule(const A, B: TPointF; R0, R1: Single; Glow: Boolean);
    procedure MarkPath(const Path: TMarkerPath; Elapsed: Double; FirstSegment: Integer);
    procedure BlendStroke(const Style: TStrokeStyle);
  public
    // The buffer is owned by the renderer and may change on the next render.
    function Render(const Paths: TMarkerPaths; SourceWidth, SourceHeight, Width,
      Height: Integer; Elapsed: Double): TRGBAPixels;
    // Draw one active stroke over the preceding Render. Append is valid when
    // the existing path points are unchanged and only new points were added.
    function RenderPreview(const Path: TMarkerPath; Append: Boolean): TRGBAPixels;
    function FinishPreview(Keep: Boolean): TRGBAPixels;
  end;

implementation

uses System.Math;

const
  TileSize = 16;

var
  GlowReach: array[0..119] of Double;

procedure TMarkerRenderer.MarkCapsule(const A, B: TPointF; R0, R1: Single; Glow: Boolean);
var
  I, MinX, MaxX, MinY, MaxY, Parts, TileX, TileY, TileIndex, Minimum: Integer;
  Left, Top, Right, Bottom: Integer;
  V, S0, S1: TPointF;
  F0, F1, MaxRadius, LengthSquared, Halo: Single;
  SegmentLength, AxisX, AxisY, Guard: Double;
  HalfWidth, HalfHeight, DX, DY, Along, Across, AlongPad, AcrossPad: Double;
  First, Last, Nearest, Farthest, MinRadius, Reach, PastEnd, Side: Double;

  function RasterArea(Left, Top, Right, Bottom: Integer; Solid: Boolean): Byte;
  var
    X, Y, Index, Coverage: Integer;
    PX, PY, QX, QY, U, Radius, Distance: Single;
    Intensity: Double;
    Preview: Boolean;
  begin
    Preview := FPreviewBase <> nil;
    Result := 255;
    for Y := Top to Bottom do
    begin
      Index := Y * FWidth + Left;
      for X := Left to Right do
      begin
        if FCoverage[Index] <> 255 then
        begin
          Coverage := 255;
          if not Solid then
          begin
            PX := X + 0.5 - A.X;
            PY := Y + 0.5 - A.Y;
            U := 0;
            if LengthSquared > 0 then
              U := EnsureRange((PX * V.X + PY * V.Y) / LengthSquared, 0.0, 1.0);
            QX := V.X * U;
            QY := V.Y * U;
            QX := PX - QX;
            QY := PY - QY;
            Radius := R0 + (R1 - R0) * U;
            Distance := Sqrt(Sqr(QX) + Sqr(QY)) - Radius;
            if Distance >= 0.5 then Coverage := 0
            else if Distance > -0.5 then Coverage := Round(255 * (0.5 - Distance));
            if Glow and (Coverage < 120) and (FCoverage[Index] < 120) and (Distance < Halo) then
            begin
              Intensity := 120 * Sqr(1 - Max(0, Distance) / Halo);
              if Intensity > Max(Coverage, FCoverage[Index]) then Coverage := Round(Intensity);
            end;
          end;
          if Coverage > FCoverage[Index] then
          begin
            if (Preview and not FPreviewDirty[Index]) or
              (not Preview and (FCoverage[Index] = 0)) then
            begin
              if FCount = Length(FTouched) then SetLength(FTouched, Max(1024, FCount * 2));
              FTouched[FCount] := Index;
              Inc(FCount);
              if Preview then FPreviewDirty[Index] := True;
            end;
            FCoverage[Index] := Coverage;
          end;
          if FCoverage[Index] < Result then Result := FCoverage[Index];
        end;
        Inc(Index);
      end;
    end;
  end;

begin
  V := B - A;
  LengthSquared := Sqr(V.X) + Sqr(V.Y);
  if LengthSquared > Sqr(32) then
  begin
    Parts := Ceil(Sqrt(LengthSquared) / 32);
    S0 := A;
    for I := 1 to Parts do
    begin
      F0 := (I - 1) / Parts;
      F1 := I / Parts;
      S1 := A + V * F1;
      MarkCapsule(S0, S1, R0 + (R1 - R0) * F0, R0 + (R1 - R0) * F1, Glow);
      S0 := S1;
    end;
    Exit;
  end;
  MaxRadius := Max(R0, R1);
  Halo := 0;
  if Glow then Halo := Max(2, MaxRadius * 1.7);
  MaxRadius := MaxRadius + Halo + 1;
  MinX := Max(0, Floor(Min(A.X, B.X) - MaxRadius));
  MaxX := Min(FWidth - 1, Ceil(Max(A.X, B.X) + MaxRadius));
  MinY := Max(0, Floor(Min(A.Y, B.Y) - MaxRadius));
  MaxY := Min(FHeight - 1, Ceil(Max(A.Y, B.Y) + MaxRadius));
  if (MinX > MaxX) or (MinY > MaxY) then Exit;
  if MaxRadius < TileSize then
  begin
    RasterArea(MinX, MinY, MaxX, MaxY, False);
    Exit;
  end;

  SegmentLength := Sqrt(LengthSquared);
  AxisX := 1;
  AxisY := 0;
  if SegmentLength > 0 then
  begin
    AxisX := V.X / SegmentLength;
    AxisY := V.Y / SegmentLength;
  end;
  // Bounds use projected pixel centers; leave room for rounding in the
  // single-precision coverage calculation on the tile's boundary.
  Guard := 0.0625 + (Max(Abs(A.X), Abs(A.Y)) + MaxRadius) * 1E-6;
  for TileY := MinY div TileSize to MaxY div TileSize do
  begin
    Top := TileY * TileSize;
    Bottom := Min(Top + TileSize - 1, FHeight - 1);
    HalfHeight := (Bottom - Top) * 0.5;
    DY := Top + HalfHeight + 0.5 - A.Y;
    for TileX := MinX div TileSize to MaxX div TileSize do
    begin
      TileIndex := TileY * FTilesAcross + TileX;
      Minimum := FTileMinimum[TileIndex];
      if Minimum = 255 then Continue;
      Left := TileX * TileSize;
      Right := Min(Left + TileSize - 1, FWidth - 1);
      HalfWidth := (Right - Left) * 0.5;
      DX := Left + HalfWidth + 0.5 - A.X;
      Along := DX * AxisX + DY * AxisY;
      Across := Abs(DY * AxisX - DX * AxisY);
      AlongPad := HalfWidth * Abs(AxisX) + HalfHeight * Abs(AxisY);
      AcrossPad := HalfWidth * Abs(AxisY) + HalfHeight * Abs(AxisX);
      First := Along - AlongPad;
      Last := Along + AlongPad;
      Nearest := R0;
      Farthest := R0;
      if SegmentLength > 0 then
      begin
        Nearest := R0 + (R1 - R0) * EnsureRange(First / SegmentLength, 0.0, 1.0);
        Farthest := R0 + (R1 - R0) * EnsureRange(Last / SegmentLength, 0.0, 1.0);
      end;
      // The mask holds the maximum coverage of this stroke. If the entire
      // tile is already at least as covered as this capsule, skip its pixels.
      Reach := 0.5 - (Minimum + 0.5) / 255;
      if Glow and (Minimum <= High(GlowReach)) then
        Reach := Max(Reach, Halo * GlowReach[Minimum]);
      Reach := Max(Nearest, Farthest) + Reach + Guard;
      PastEnd := Max(0, Max(-Last, First - SegmentLength));
      Side := Max(0, Across - AcrossPad);
      if (Reach <= 0) or (Sqr(PastEnd) + Sqr(Side) > Sqr(Reach)) then Continue;

      MinRadius := Min(Nearest, Farthest) - 0.5 - Guard;
      PastEnd := Max(0, Max(-First, Last - SegmentLength));
      Side := Across + AcrossPad;
      FTileMinimum[TileIndex] := RasterArea(Left, Top, Right, Bottom,
        (MinRadius > 0) and (Sqr(PastEnd) + Sqr(Side) < Sqr(MinRadius)));
      FTilesUsed := True;
    end;
  end;
end;

procedure TMarkerRenderer.ClearTileMinimum;
begin
  if not FTilesUsed then Exit;
  FillChar(FTileMinimum[0], Length(FTileMinimum), 0);
  FTilesUsed := False;
end;

procedure TMarkerRenderer.BlendStroke(const Style: TStrokeStyle);
var
  I, Index, A, DestWeight, Total, R, G, B: Integer;
  P: PPIXEL_RGBA;
  Preview: Boolean;
begin
  Preview := FPreviewBase <> nil;
  R := (Style.RGB shr 16) and 255;
  G := (Style.RGB shr 8) and 255;
  B := Style.RGB and 255;
  for I := 0 to FCount - 1 do
  begin
    Index := FTouched[I];
    A := (Integer(FCoverage[Index]) * Style.Opacity + 50) div 100;
    if Preview then FPreviewDirty[Index] := False
    else FCoverage[Index] := 0;
    if A = 0 then Continue;
    P := @FPixels[Index];
    if Preview then P^ := FPreviewBase[Index];
    if (A = 255) or (P^.A = 0) then
    begin
      P^.R := R;
      P^.G := G;
      P^.B := B;
      P^.A := A;
      Continue;
    end;
    DestWeight := (Integer(P^.A) * (255 - A) + 127) div 255;
    Total := A + DestWeight;
    P^.R := (R * A + P^.R * DestWeight + Total div 2) div Total;
    P^.G := (G * A + P^.G * DestWeight + Total div 2) div Total;
    P^.B := (B * A + P^.B * DestWeight + Total div 2) div Total;
    P^.A := Total;
  end;
  FCount := 0;
  if not Preview then ClearTileMinimum;
end;

procedure TMarkerRenderer.MarkPath(const Path: TMarkerPath; Elapsed: Double; FirstSegment: Integer);
var
  I: Integer;
  A, B: TPathPoint;
  P, Q, V: TPointF;
  T, Radius, R0, R1, DashOn, DashCycle, Span, Offset, Phase, StopAt: Double;
  Glow: Boolean;
  function PointRadius(Pressure: Double): Single;
  begin
    Result := Radius * (0.21 + 0.79 * Pressure);
  end;
  function Position(const Raw: TPointF): TPointF;
  begin
    Result := PointF(Raw.X * FScaleX, Raw.Y * FScaleY);
  end;
begin
  if (Path.Style.Opacity = 0) or (Length(Path.Points) = 0) then Exit;
  Radius := Path.Style.Width * FWidthScale * 0.5;
  Glow := Path.Style.Kind = pkGlow;
  A := Path.Points[FirstSegment - 1];
  P := Position(A.Position);
  if Length(Path.Points) = 1 then
    MarkCapsule(P, P, PointRadius(A.Pressure), PointRadius(A.Pressure), Glow);
  DashOn := Max(Path.Style.Width * 2.4, 4);
  DashCycle := DashOn + Max(Path.Style.Width * 1.55, 3);
  for I := FirstSegment to High(Path.Points) do
  begin
    B := Path.Points[I];
    T := 1;
    if B.Time > Elapsed then T := EnsureRange((Elapsed - A.Time) / (B.Time - A.Time), 0.0, 1.0);
    V := Position(B.Position) - P;
    R0 := PointRadius(A.Pressure);
    R1 := PointRadius(B.Pressure);
    if Path.Style.Kind = pkDash then
    begin
      Span := B.Distance - A.Distance;
      StopAt := Span * T;
      Offset := 0;
      while Offset < StopAt do
      begin
        Phase := A.Distance + Offset - Floor((A.Distance + Offset) / DashCycle) * DashCycle;
        if Phase < DashOn then
        begin
          Q := P + V * (Offset / Span);
          T := Min(StopAt, Offset + Max(0.0001, DashOn - Phase));
          MarkCapsule(Q, P + V * (T / Span), R0 + (R1 - R0) * Offset / Span,
            R0 + (R1 - R0) * T / Span, False);
          Offset := T;
        end
        else Offset := Offset + Max(0.0001, DashCycle - Phase);
      end;
    end
    else MarkCapsule(P, P + V * T, R0, R0 + (R1 - R0) * T, Glow);
    if B.Time > Elapsed then Break;
    A := B;
    P := Position(A.Position);
  end;
end;

procedure TMarkerRenderer.ResetPreview;
begin
  FPreviewPoints := 0;
  FillChar(FCoverage[0], Length(FCoverage), 0);
  ClearTileMinimum;
end;

function TMarkerRenderer.RenderPreview(const Path: TMarkerPath; Append: Boolean): TRGBAPixels;
var PointCount: Integer;
begin
  if Length(FPixels) = 0 then Exit(nil);
  PointCount := Length(Path.Points);
  if FPreviewBase = nil then
  begin
    FPreviewBase := Copy(FPixels);
    SetLength(FPreviewDirty, Length(FPixels));
  end
  else
  begin
    Append := Append and (PointCount >= FPreviewPoints) and
      (Path.Style.Kind = FPreviewStyle.Kind) and (Path.Style.Width = FPreviewStyle.Width) and
      (Path.Style.Opacity = FPreviewStyle.Opacity) and (Path.Style.RGB = FPreviewStyle.RGB);
    if Append and (PointCount = FPreviewPoints) then Exit(FPixels);
    // The standalone dot is replaced by the first segment, especially when
    // pressure drops sharply on that segment.
    if not Append or (FPreviewPoints = 1) then
    begin
      Move(FPreviewBase[0], FPixels[0], Length(FPixels) * SizeOf(TPIXEL_RGBA));
      ResetPreview;
    end;
  end;
  MarkPath(Path, 1E20, Max(1, FPreviewPoints));
  BlendStroke(Path.Style);
  FPreviewStyle := Path.Style;
  FPreviewPoints := PointCount;
  Result := FPixels;
end;

function TMarkerRenderer.FinishPreview(Keep: Boolean): TRGBAPixels;
begin
  if FPreviewBase <> nil then
  begin
    if not Keep then Move(FPreviewBase[0], FPixels[0], Length(FPixels) * SizeOf(TPIXEL_RGBA));
    ResetPreview;
    FPreviewBase := nil;
  end;
  Result := FPixels;
end;

function TMarkerRenderer.Render(const Paths: TMarkerPaths; SourceWidth, SourceHeight,
  Width, Height: Integer; Elapsed: Double): TRGBAPixels;
var Path: TMarkerPath; Size: Integer;
begin
  if (Width <= 0) or (Height <= 0) or (SourceWidth <= 0) or (SourceHeight <= 0) or
    (Int64(Width) * Height > 40 * 1024 * 1024) then Exit(nil);
  FinishPreview(True);
  FWidth := Width;
  FHeight := Height;
  FScaleX := Width / SourceWidth;
  FScaleY := Height / SourceHeight;
  FWidthScale := Min(FScaleX, FScaleY);
  Size := Width * Height;
  SetLength(FPixels, Size);
  SetLength(FCoverage, Size);
  FTilesAcross := (Width + TileSize - 1) div TileSize;
  SetLength(FTileMinimum, FTilesAcross * ((Height + TileSize - 1) div TileSize));
  FillChar(FPixels[0], Size * SizeOf(TPIXEL_RGBA), 0);
  for Path in Paths do
  begin
    if Path.Start >= Elapsed then Break;
    MarkPath(Path, Elapsed - Path.Start, 1);
    BlendStroke(Path.Style);
  end;
  Result := FPixels;
end;

procedure InitializeGlowReach;
var I: Integer;
begin
  for I := Low(GlowReach) to High(GlowReach) do
    GlowReach[I] := 1 - Sqrt((I + 0.5) / 120);
end;

initialization
  InitializeGlowReach;

end.
