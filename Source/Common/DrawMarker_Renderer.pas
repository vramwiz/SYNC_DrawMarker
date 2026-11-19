unit DrawMarker_Renderer;

interface

uses DrawMarker_Curves, DrawMarker_Model, AviUtl2FilterTypes, System.Types;

type
  TMarkerRenderer = class
  private
    FWidth, FHeight: Integer;
    FScaleX, FScaleY, FWidthScale: Single;
    FPixels: TRGBAPixels;
    FCoverage: TArray<Byte>;
    FTouched: TArray<Integer>;
    FCount: Integer;
    procedure MarkCapsule(const A, B: TPointF; R0, R1: Single; Glow: Boolean);
    procedure DrawPath(const Path: TMarkerPath; Elapsed: Double);
    procedure BlendStroke(const Style: TStrokeStyle);
  public
    // Result belongs to the renderer and remains valid until the next Render.
    function Render(const Paths: TMarkerPaths; SourceWidth, SourceHeight, Width,
      Height: Integer; Elapsed: Double): TRGBAPixels;
  end;

implementation

uses System.Math;

procedure TMarkerRenderer.MarkCapsule(const A, B: TPointF; R0, R1: Single; Glow: Boolean);
var
  I, X, Y, MinX, MaxX, MinY, MaxY, Index, Coverage, Parts: Integer;
  V, P, Q, S0, S1: TPointF;
  U, F0, F1, Radius, Distance, MaxRadius, LengthSquared, Halo: Single;
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
  for Y := MinY to MaxY do
  begin
    Index := Y * FWidth + MinX;
    for X := MinX to MaxX do
    begin
      P := PointF(X + 0.5 - A.X, Y + 0.5 - A.Y);
      U := 0;
      if LengthSquared > 0 then
        U := EnsureRange((P.X * V.X + P.Y * V.Y) / LengthSquared, 0.0, 1.0);
      Q := P - V * U;
      Radius := R0 + (R1 - R0) * U;
      Distance := Sqrt(Sqr(Q.X) + Sqr(Q.Y)) - Radius;
      Coverage := Round(255 * EnsureRange(0.5 - Distance, 0.0, 1.0));
      if Glow and (Distance > -0.5) and (Distance < Halo) then
        Coverage := Max(Coverage, Round(120 * Sqr(1 - Max(0, Distance) / Halo)));
      if Coverage > FCoverage[Index] then
      begin
        if FCoverage[Index] = 0 then
        begin
          if FCount = Length(FTouched) then SetLength(FTouched, Max(1024, FCount * 2));
          FTouched[FCount] := Index;
          Inc(FCount);
        end;
        FCoverage[Index] := Coverage;
      end;
      Inc(Index);
    end;
  end;
end;

procedure TMarkerRenderer.BlendStroke(const Style: TStrokeStyle);
var I, Index, A, DestWeight, Total, R, G, B: Integer; P: PPIXEL_RGBA;
begin
  R := (Style.RGB shr 16) and 255;
  G := (Style.RGB shr 8) and 255;
  B := Style.RGB and 255;
  for I := 0 to FCount - 1 do
  begin
    Index := FTouched[I];
    A := (Integer(FCoverage[Index]) * Style.Opacity + 50) div 100;
    FCoverage[Index] := 0;
    if A = 0 then Continue;
    P := @FPixels[Index];
    DestWeight := (Integer(P^.A) * (255 - A) + 127) div 255;
    Total := A + DestWeight;
    P^.R := (R * A + P^.R * DestWeight + Total div 2) div Total;
    P^.G := (G * A + P^.G * DestWeight + Total div 2) div Total;
    P^.B := (B * A + P^.B * DestWeight + Total div 2) div Total;
    P^.A := Total;
  end;
  FCount := 0;
end;

procedure TMarkerRenderer.DrawPath(const Path: TMarkerPath; Elapsed: Double);
var
  I: Integer;
  A, B: TPathPoint;
  P, Q, V: TPointF;
  T, Radius, R0, R1, DashOn, DashCycle, Span, Offset, Phase, StopAt: Double;
  Glow: Boolean;
  function PointRadius(Pressure: Double): Single;
  begin
    if Path.Style.UsePressure or (Path.Style.Kind = pkBrush) then
      Result := Radius * (0.21 + 0.79 * Pressure)
    else Result := Radius;
  end;
  function Position(const Raw: TPointF): TPointF;
  begin
    Result := PointF(Raw.X * FScaleX, Raw.Y * FScaleY);
  end;
begin
  if (Path.Style.Opacity = 0) or (Length(Path.Points) = 0) then Exit;
  Radius := Path.Style.Width * FWidthScale * 0.5;
  Glow := Path.Style.Kind = pkGlow;
  A := Path.Points[0];
  P := Position(A.Position);
  if Length(Path.Points) = 1 then
    MarkCapsule(P, P, PointRadius(A.Pressure), PointRadius(A.Pressure), Glow);
  DashOn := Max(Path.Style.Width * 2.4, 4);
  DashCycle := DashOn + Max(Path.Style.Width * 1.55, 3);
  for I := 1 to High(Path.Points) do
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
  BlendStroke(Path.Style);
end;

function TMarkerRenderer.Render(const Paths: TMarkerPaths; SourceWidth, SourceHeight,
  Width, Height: Integer; Elapsed: Double): TRGBAPixels;
var Path: TMarkerPath; Size: Integer;
begin
  if (Width <= 0) or (Height <= 0) or (SourceWidth <= 0) or (SourceHeight <= 0) or
    (Int64(Width) * Height > 40 * 1024 * 1024) then Exit(nil);
  FWidth := Width;
  FHeight := Height;
  FScaleX := Width / SourceWidth;
  FScaleY := Height / SourceHeight;
  FWidthScale := Min(FScaleX, FScaleY);
  Size := Width * Height;
  SetLength(FPixels, Size);
  SetLength(FCoverage, Size);
  FillChar(FPixels[0], Size * SizeOf(TPIXEL_RGBA), 0);
  for Path in Paths do
  begin
    if Path.Start >= Elapsed then Break;
    DrawPath(Path, Elapsed - Path.Start);
  end;
  Result := FPixels;
end;

end.
