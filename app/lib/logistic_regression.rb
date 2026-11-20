# frozen_string_literal: true

# Binary logistic regression fit by Newton's method (IRLS) with an L2 penalty
# on every weight except the intercept. Small and dependency-free: meant for a
# handful of features and up to a few hundred thousand rows.
class LogisticRegression
  attr_reader :intercept, :weights, :iterations

  def self.fit(rows, labels, **options)
    new(rows, labels, **options).tap(&:fit)
  end

  def initialize(rows, labels, l2: 1.0, max_iterations: 50, tolerance: 1e-8)
    raise ArgumentError, "rows and labels differ in length" if rows.size != labels.size
    raise ArgumentError, "no rows to fit" if rows.empty?

    @rows = rows
    @labels = labels
    @l2 = l2
    @max_iterations = max_iterations
    @tolerance = tolerance
  end

  def fit
    dimension = @rows.first.size + 1
    beta = Array.new(dimension, 0.0)

    (1..@max_iterations).each do |iteration|
      @iterations = iteration
      gradient = Array.new(dimension, 0.0)
      hessian = Array.new(dimension) { Array.new(dimension, 0.0) }

      @rows.each_with_index do |row, index|
        x = [1.0, *row]
        probability = self.class.sigmoid(dot(beta, x))
        residual = @labels[index] - probability
        curvature = probability * (1 - probability)

        dimension.times do |a|
          gradient[a] += residual * x[a]
          (a...dimension).each { |b| hessian[a][b] += curvature * x[a] * x[b] }
        end
      end

      dimension.times do |a|
        (0...a).each { |b| hessian[a][b] = hessian[b][a] }
        # The intercept is unpenalized; a tiny ridge keeps the system solvable
        # when every row is predicted with certainty.
        penalty = a.zero? ? 1e-9 : @l2
        gradient[a] -= penalty * beta[a] unless a.zero?
        hessian[a][a] += penalty
      end

      step = solve(hessian, gradient)
      beta = beta.zip(step).map(&:sum)
      break if step.map(&:abs).max < @tolerance
    end

    @intercept = beta.first
    @weights = beta.drop(1)
    self
  end

  def probability(row)
    self.class.sigmoid(@intercept + dot(@weights, row))
  end

  def self.sigmoid(z)
    if z >= 0
      1.0 / (1.0 + Math.exp(-z))
    else
      exp = Math.exp(z)
      exp / (1.0 + exp)
    end
  end

  private

  def dot(a, b)
    a.each_with_index.sum { |value, index| value * b[index] }
  end

  # Gaussian elimination with partial pivoting.
  def solve(matrix, vector)
    size = vector.size
    augmented = matrix.each_with_index.map { |row, index| row.dup << vector[index] }

    size.times do |column|
      pivot = (column...size).max_by { |row| augmented[row][column].abs }
      augmented[column], augmented[pivot] = augmented[pivot], augmented[column]

      ((column + 1)...size).each do |row|
        factor = augmented[row][column] / augmented[column][column]
        (column..size).each { |index| augmented[row][index] -= factor * augmented[column][index] }
      end
    end

    solution = Array.new(size, 0.0)
    (size - 1).downto(0) do |row|
      known = ((row + 1)...size).sum { |index| augmented[row][index] * solution[index] }
      solution[row] = (augmented[row][size] - known) / augmented[row][row]
    end
    solution
  end

end
