unit DrawMarker_Renderer;

interface

uses DrawMarker_Curves, DrawMarker_Model, AviUtl2FilterTypes, System.Types, System.Math;

type
  TMarkerRenderer = class
  private type
    TTipPolygon = record
      Count: Integer;
      Vertices: array[0..3] of TPointF;
    end;
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
    class function MakeTip(Shape: TTipShape; Rotation: Integer): TTipPolygon; static;
    procedure RecordCoverage(Index, Coverage: Integer; Preview: Boolean); inline;
    procedure MarkCapsule(const A, B: TPointF; R0, R1, D0, D1: Single; Glow: Boolean);
    procedure MarkPolygon(const Tip: TTipPolygon; const A, B: TPointF;
      R0, R1, D0, D1: Single; Glow: Boolean);
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

const
  TileSize = 16;
  TextureSize = 256;
  TextureMask = TextureSize - 1;

type
  TBrushTexture = array[0..TextureMask, 0..TextureMask] of Byte;
  PBrushTexture = ^TBrushTexture;

var
  GlowReach: array[0..119] of Double;
  ChalkTexture, PencilTexture, CrayonTexture: TBrushTexture;

function CoverageAtDistance(Distance, Halo: Single; Previous: Integer): Integer; inline;
var Intensity: Double;
begin
  if Distance >= 0.5 then Result := 0
  else if Distance > -0.5 then Result := Round(255 * (0.5 - Distance))
  else Result := 255;
  if (Halo > 0) and (Result < 120) and (Previous < 120) and (Distance < Halo) then
  begin
    Intensity := 120 * Sqr(1 - Max(0, Distance) / Halo);
    if Intensity > Max(Result, Previous) then Result := Round(Intensity);
  end;
end;

function CoverageReach(Minimum: Integer; Halo: Single): Double; inline;
begin
  Result := 0.5 - (Minimum + 0.5) / 255;
  if (Halo > 0) and (Minimum <= High(GlowReach)) then
    Result := Max(Result, Halo * GlowReach[Minimum]);
end;

procedure TMarkerRenderer.RecordCoverage(Index, Coverage: Integer; Preview: Boolean);
begin
  if Coverage <= FCoverage[Index] then Exit;
  if (Preview and not FPreviewDirty[Index]) or (not Preview and (FCoverage[Index] = 0)) then
  begin
    if FCount = Length(FTouched) then SetLength(FTouched, Max(1024, FCount * 2));
    FTouched[FCount] := Index;
    Inc(FCount);
    if Preview then FPreviewDirty[Index] := True;
  end;
  FCoverage[Index] := Coverage;
end;

procedure TMarkerRenderer.MarkCapsule(const A, B: TPointF; R0, R1, D0, D1: Single; Glow: Boolean);
var
  I, MinX, MaxX, MinY, MaxY, Parts, TileX, TileY, TileIndex, Minimum, MaxCoverage: Integer;
  Left, Top, Right, Bottom: Integer;
  V, S0, S1: TPointF;
  F0, F1, MaxRadius, LengthSquared, Halo: Single;
  SegmentLength, AxisX, AxisY, Guard: Double;
  HalfWidth, HalfHeight, DX, DY, Along, Across, AlongPad, AcrossPad: Double;
  First, Last, Nearest, Farthest, MinRadius, Reach, PastEnd, Side: Double;
  ScaleDensity: Boolean;

  function RasterArea(Left, Top, Right, Bottom: Integer; Solid: Boolean): Byte;
  var
    X, Y, Index, Coverage: Integer;
    PX, PY, QX, QY, U, Radius, Distance: Single;
    Preview: Boolean;
  begin
    Preview := FPreviewBase <> nil;
    Result := 255;
    for Y := Top to Bottom do
    begin
      Index := Y * FWidth + Left;
      for X := Left to Right do
      begin
        if FCoverage[Index] < MaxCoverage then
        begin
          Coverage := MaxCoverage;
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
            Coverage := CoverageAtDistance(Distance, Halo, FCoverage[Index]);
            if ScaleDensity then Coverage := Round(Coverage * (D0 + (D1 - D0) * U));
          end;
          RecordCoverage(Index, Coverage, Preview);
        end;
        if FCoverage[Index] < Result then Result := FCoverage[Index];
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
      MarkCapsule(S0, S1, R0 + (R1 - R0) * F0, R0 + (R1 - R0) * F1,
        D0 + (D1 - D0) * F0, D0 + (D1 - D0) * F1, Glow);
      S0 := S1;
    end;
    Exit;
  end;
  MaxRadius := Max(R0, R1);
  MaxCoverage := Round(255 * Max(D0, D1));
  ScaleDensity := (D0 <> 1) or (D1 <> 1);
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
      if Minimum >= MaxCoverage then Continue;
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
      Reach := CoverageReach(Minimum, Halo);
      Reach := Max(Nearest, Farthest) + Reach + Guard;
      PastEnd := Max(0, Max(-Last, First - SegmentLength));
      Side := Max(0, Across - AcrossPad);
      if (Reach <= 0) or (Sqr(PastEnd) + Sqr(Side) > Sqr(Reach)) then Continue;

      MinRadius := Min(Nearest, Farthest) - 0.5 - Guard;
      PastEnd := Max(0, Max(-First, Last - SegmentLength));
      Side := Across + AcrossPad;
      FTileMinimum[TileIndex] := RasterArea(Left, Top, Right, Bottom,
        (D0 = D1) and (MinRadius > 0) and (Sqr(PastEnd) + Sqr(Side) < Sqr(MinRadius)));
      FTilesUsed := True;
    end;
  end;
end;

class function TMarkerRenderer.MakeTip(Shape: TTipShape; Rotation: Integer): TTipPolygon;
const TriangleHalfBaseHeight = 0.577350269;
var
  I: Integer;
  HalfHeight, Sine, Cosine: Single;
  P: TPointF;
begin
  Result := Default(TTipPolygon);
  case Shape of
    tsRound: Exit;
    tsTriangle:
      begin
        Result.Count := 3;
        Result.Vertices[0] := PointF(0, -2 * TriangleHalfBaseHeight);
        Result.Vertices[1] := PointF(1, TriangleHalfBaseHeight);
        Result.Vertices[2] := PointF(-1, TriangleHalfBaseHeight);
      end;
    tsSquare, tsRectangle:
      begin
        HalfHeight := 1;
        if Shape = tsRectangle then HalfHeight := 0.5;
        Result.Count := 4;
        Result.Vertices[0] := PointF(-1, -HalfHeight);
        Result.Vertices[1] := PointF(1, -HalfHeight);
        Result.Vertices[2] := PointF(1, HalfHeight);
        Result.Vertices[3] := PointF(-1, HalfHeight);
      end;
  end;
  if Rotation = 0 then Exit;
  SinCos(DegToRad(Rotation), Sine, Cosine);
  for I := 0 to Result.Count - 1 do
  begin
    P := Result.Vertices[I];
    Result.Vertices[I] := PointF(P.X * Cosine - P.Y * Sine, P.X * Sine + P.Y * Cosine);
  end;
end;

procedure TMarkerRenderer.MarkPolygon(const Tip: TTipPolygon; const A, B: TPointF;
  R0, R1, D0, D1: Single; Glow: Boolean);
type
  TEdge = record
    NX, NY, Offset: Double;
  end;
var
  Vertices: array[0..7] of TPointF;
  Hull: array[0..15] of TPointF;
  Edges: array[0..7] of TEdge;
  V, P, Q: TPointF;
  I, J, Count, Turnaround, Minimum, MaxCoverage: Integer;
  MinX, MinY, MaxX, MaxY, Left, Top, Right, Bottom, TileX, TileY, TileIndex: Integer;
  Halo: Single;
  BoundsPad, EdgeLength, LowX, HighX, LowY, HighY, ProjectionScale: Double;
  HalfWidth, HalfHeight, CenterX, CenterY, Distance, Extent, Nearest, Farthest: Double;
  VariableDensity: Boolean;

  procedure AddHullPoint(const Point: TPointF; MinCount: Integer);
  var First, Last: TPointF;
  begin
    while Count >= MinCount do
    begin
      First := Hull[Count - 2];
      Last := Hull[Count - 1];
      if (Last.X - First.X) * (Point.Y - First.Y) >
        (Last.Y - First.Y) * (Point.X - First.X) then Break;
      Dec(Count);
    end;
    Hull[Count] := Point;
    Inc(Count);
  end;

  function RasterArea(Left, Top, Right, Bottom: Integer; Solid: Boolean): Byte;
  var
    X, Y, Index, Edge, Coverage: Integer;
    RowOffsets: array[0..7] of Double;
    PixelDistance, T: Double;
    Preview: Boolean;
  begin
    Preview := FPreviewBase <> nil;
    Result := 255;
    for Y := Top to Bottom do
    begin
      if not Solid then
        for Edge := 0 to Count - 1 do
          RowOffsets[Edge] := (Y + 0.5) * Edges[Edge].NY - Edges[Edge].Offset;
      Index := Y * FWidth + Left;
      for X := Left to Right do
      begin
        if FCoverage[Index] < MaxCoverage then
        begin
          Coverage := MaxCoverage;
          if not Solid then
          begin
            PixelDistance := (X + 0.5) * Edges[0].NX + RowOffsets[0];
            for Edge := 1 to Count - 1 do
              PixelDistance := Max(PixelDistance, (X + 0.5) * Edges[Edge].NX + RowOffsets[Edge]);
            Coverage := CoverageAtDistance(PixelDistance, Halo, FCoverage[Index]);
            if VariableDensity then
            begin
              T := EnsureRange(((X + 0.5 - A.X) * V.X + (Y + 0.5 - A.Y) * V.Y) *
                ProjectionScale, 0.0, 1.0);
              Coverage := Round(Coverage * (D0 + (D1 - D0) * T));
            end
            else if D0 <> 1 then Coverage := Round(Coverage * D0);
          end;
          RecordCoverage(Index, Coverage, Preview);
        end;
        if FCoverage[Index] < Result then Result := FCoverage[Index];
        Inc(Index);
      end;
    end;
  end;

begin
  // The convex hull of the two tips sweeps their whole span, including
  // nonuniform pressure, without gaps between pen samples.
  for I := 0 to Tip.Count - 1 do
  begin
    Vertices[I] := A + Tip.Vertices[I] * R0;
    Vertices[Tip.Count + I] := B + Tip.Vertices[I] * R1;
  end;
  for I := 1 to Tip.Count * 2 - 1 do
  begin
    P := Vertices[I];
    J := I;
    while (J > 0) and ((Vertices[J - 1].X > P.X) or
      ((Vertices[J - 1].X = P.X) and (Vertices[J - 1].Y > P.Y))) do
    begin
      Vertices[J] := Vertices[J - 1];
      Dec(J);
    end;
    Vertices[J] := P;
  end;
  Count := 0;
  for I := 0 to Tip.Count * 2 - 1 do AddHullPoint(Vertices[I], 2);
  Turnaround := Count + 1;
  for I := Tip.Count * 2 - 2 downto 0 do AddHullPoint(Vertices[I], Turnaround);
  Dec(Count);
  if Count < 3 then Exit;

  Halo := 0;
  if Glow then Halo := Max(2, Max(R0, R1) * 1.7);
  // A corner can extend the glow beyond the distance measured at an edge.
  BoundsPad := 2 * Halo + 1;
  LowX := Hull[0].X;
  HighX := LowX;
  LowY := Hull[0].Y;
  HighY := LowY;
  for I := 0 to Count - 1 do
  begin
    P := Hull[I];
    Q := Hull[I + 1];
    LowX := Min(LowX, P.X);
    HighX := Max(HighX, P.X);
    LowY := Min(LowY, P.Y);
    HighY := Max(HighY, P.Y);
    EdgeLength := Hypot(Double(Q.X) - P.X, Double(Q.Y) - P.Y);
    Edges[I].NX := (Double(Q.Y) - P.Y) / EdgeLength;
    Edges[I].NY := (Double(P.X) - Q.X) / EdgeLength;
    Edges[I].Offset := Edges[I].NX * P.X + Edges[I].NY * P.Y;
  end;
  MinX := Max(0, Floor(LowX - BoundsPad));
  MaxX := Min(FWidth - 1, Ceil(HighX + BoundsPad));
  MinY := Max(0, Floor(LowY - BoundsPad));
  MaxY := Min(FHeight - 1, Ceil(HighY + BoundsPad));
  if (MinX > MaxX) or (MinY > MaxY) then Exit;

  V := B - A;
  VariableDensity := (D0 <> D1) and ((V.X <> 0) or (V.Y <> 0));
  ProjectionScale := 0;
  if VariableDensity then ProjectionScale := 1 / (Sqr(Double(V.X)) + Sqr(Double(V.Y)))
  else D0 := Max(D0, D1);
  MaxCoverage := Round(255 * Max(D0, D1));
  if (MaxX - MinX < TileSize) and (MaxY - MinY < TileSize) then
  begin
    RasterArea(MinX, MinY, MaxX, MaxY, False);
    Exit;
  end;
  for TileY := MinY div TileSize to MaxY div TileSize do
  begin
    Top := TileY * TileSize;
    Bottom := Min(Top + TileSize - 1, FHeight - 1);
    HalfHeight := (Bottom - Top) * 0.5;
    CenterY := Top + HalfHeight + 0.5;
    for TileX := MinX div TileSize to MaxX div TileSize do
    begin
      TileIndex := TileY * FTilesAcross + TileX;
      Minimum := FTileMinimum[TileIndex];
      if Minimum >= MaxCoverage then Continue;
      Left := TileX * TileSize;
      Right := Min(Left + TileSize - 1, FWidth - 1);
      HalfWidth := (Right - Left) * 0.5;
      CenterX := Left + HalfWidth + 0.5;
      Nearest := -Infinity;
      Farthest := -Infinity;
      for I := 0 to Count - 1 do
      begin
        Distance := CenterX * Edges[I].NX + CenterY * Edges[I].NY - Edges[I].Offset;
        Extent := HalfWidth * Abs(Edges[I].NX) + HalfHeight * Abs(Edges[I].NY);
        Nearest := Max(Nearest, Distance - Extent);
        Farthest := Max(Farthest, Distance + Extent);
      end;
      if Nearest > CoverageReach(Minimum, Halo) + 1E-6 then Continue;
      FTileMinimum[TileIndex] := RasterArea(Left, Top, Right, Bottom,
        not VariableDensity and (Farthest < -0.500001));
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
  I, Index, A, DestWeight, Total, R, G, B, X, Y, Opacity: Integer;
  P: PPIXEL_RGBA;
  Texture: PBrushTexture;
  Preview: Boolean;
begin
  Preview := FPreviewBase <> nil;
  Opacity := 100 - Style.Transparency;
  Texture := nil;
  case Style.Kind of
    pkChalk: Texture := @ChalkTexture;
    pkPencil: Texture := @PencilTexture;
    pkCrayon: Texture := @CrayonTexture;
  end;
  R := (Style.RGB shr 16) and 255;
  G := (Style.RGB shr 8) and 255;
  B := Style.RGB and 255;
  for I := 0 to FCount - 1 do
  begin
    Index := FTouched[I];
    if Texture <> nil then
    begin
      Y := Index div FWidth;
      X := Index - Y * FWidth;
      A := (Integer(FCoverage[Index]) * Texture^[Y and TextureMask, X and TextureMask] *
        Opacity + 12750) div 25500;
    end
    else A := (Integer(FCoverage[Index]) * Opacity + 50) div 100;
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
  T, Radius, R0, R1, D0, D1, DashOn, DashCycle, Span, Offset, Phase, StopAt: Double;
  Glow, Pencil: Boolean;
  Tip: TTipPolygon;

  function PointRadius(Pressure: Double): Single;
  begin
    Result := Radius * (0.21 + 0.79 * Pressure);
  end;

  function PointDensity(Pressure: Double): Double;
  begin
    if Pencil then Result := 0.22 + 0.78 * Pressure else Result := 1;
  end;

  function Position(const Raw: TPointF): TPointF;
  begin
    Result := PointF(Raw.X * FScaleX, Raw.Y * FScaleY);
  end;

  procedure MarkTip(const StartPoint, EndPoint: TPointF; StartRadius, EndRadius,
    StartDensity, EndDensity: Single);
  begin
    if Tip.Count = 0 then
      MarkCapsule(StartPoint, EndPoint, StartRadius, EndRadius, StartDensity, EndDensity, Glow)
    else
      MarkPolygon(Tip, StartPoint, EndPoint, StartRadius, EndRadius, StartDensity, EndDensity, Glow);
  end;

begin
  if (Path.Style.Transparency = 100) or (Length(Path.Points) = 0) then Exit;
  Radius := Path.Style.Width * FWidthScale * 0.5;
  Glow := Path.Style.Kind = pkGlow;
  Pencil := Path.Style.Kind = pkPencil;
  Tip := MakeTip(Path.Style.Shape, Path.Style.Rotation);
  A := Path.Points[FirstSegment - 1];
  P := Position(A.Position);
  if Length(Path.Points) = 1 then
    MarkTip(P, P, PointRadius(A.Pressure), PointRadius(A.Pressure),
      PointDensity(A.Pressure), PointDensity(A.Pressure));
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
    D0 := PointDensity(A.Pressure);
    D1 := PointDensity(B.Pressure);
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
          MarkTip(Q, P + V * (T / Span), R0 + (R1 - R0) * Offset / Span,
            R0 + (R1 - R0) * T / Span, 1, 1);
          Offset := T;
        end
        else Offset := Offset + Max(0.0001, DashCycle - Phase);
      end;
    end
    else MarkTip(P, P + V * T, R0, R0 + (R1 - R0) * T, D0, D0 + (D1 - D0) * T);
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
    Append := Append and (PointCount >= FPreviewPoints) and Path.Style.Matches(FPreviewStyle);
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

procedure InitializeBrushTextures;
const
  PatchSize = 8;
  PatchMask = TextureSize div PatchSize - 1;
var
  Patches: array[0..PatchMask, 0..PatchMask] of Byte;
  Seed: Cardinal;
  X, Y, Row, Col, NextRow, NextCol, DX, DY, Top, Bottom, Patch, Grain: Integer;

  function NextByte: Byte;
  begin
    Seed := Seed xor (Seed shl 13);
    Seed := Seed xor (Seed shr 17);
    Seed := Seed xor (Seed shl 5);
    Result := Byte(Seed and $FF);
  end;

begin
  // Fixed paper grain keeps the deposits stable when the same stroke is
  // revealed over time or redrawn. The mask still uses the usual geometry.
  Seed := $A81C7E29;
  for Row := 0 to PatchMask do
    for Col := 0 to PatchMask do
      Patches[Row, Col] := NextByte;
  for Y := 0 to TextureMask do
  begin
    Row := Y div PatchSize;
    NextRow := (Row + 1) and PatchMask;
    DY := Y mod PatchSize;
    for X := 0 to TextureMask do
    begin
      Col := X div PatchSize;
      NextCol := (Col + 1) and PatchMask;
      DX := X mod PatchSize;
      Top := Patches[Row, Col] * (PatchSize - DX) + Patches[Row, NextCol] * DX;
      Bottom := Patches[NextRow, Col] * (PatchSize - DX) + Patches[NextRow, NextCol] * DX;
      Patch := (Top * (PatchSize - DY) + Bottom * DY) div Sqr(PatchSize);
      Grain := NextByte;
      ChalkTexture[Y, X] := EnsureRange(((2 * Grain + 3 * Patch) div 5 - 70) * 3, 0, 255);
      PencilTexture[Y, X] := EnsureRange(62 + (7 * Grain + 3 * Patch) div 10, 0, 255);
      CrayonTexture[Y, X] := EnsureRange(((3 * Grain + 2 * Patch) div 5 - 40) * 3, 0, 255);
    end;
  end;
end;

initialization
  InitializeGlowReach;
  InitializeBrushTextures;

end.
