local MathUtil = {}

--
function MathUtil.Lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Serializes Vector3
function MathUtil.SerializeVector3(vector3: Vector3): { number }
	return { vector3.X, vector3.Y, vector3.Z }
end

-- Deserializes Vector3
function MathUtil.DeSerializeVector3(serializedVector3: { number }): Vector3
	return Vector3.new(serializedVector3[1], serializedVector3[2], serializedVector3[3])
end

-- Rounds up the raw amount to only get the last 2 decimals
function MathUtil.RoundUpTo2Dec(amount: number): number
	return tonumber(string.format("%.2f", amount))
end

function MathUtil.QuadraticBezier(t, p0, p1, p2)
	return (1 - t) ^ 2 * p0 + 2 * (1 - t) * t * p1 + t ^ 2 * p2
end

return MathUtil
